// ShipStream CI/CD pipeline for orders-api.
//
//   Checkout -> Lint -> Unit Test -> Build Image -> Trivy Scan -> Push
//            -> Helm Deploy -> Smoke Test -> (Rollback, only if deploy or smoke failed)
//
// DEPLOY_TARGET=local (default): kind cluster + registry at localhost:5001 (scripts/local-up.sh)
// DEPLOY_TARGET=aws:             EKS + ECR (docs/aws-mode.md)

// Run body with KUBECONFIG pointing at the target cluster.
def withCluster(Closure body) {
  if (params.DEPLOY_TARGET == 'aws') {
    withAws {
      sh 'aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --kubeconfig "$WORKSPACE/.kube/config"'
      withEnv(["KUBECONFIG=${env.WORKSPACE}/.kube/config"]) { body() }
    }
  } else {
    withCredentials([file(credentialsId: 'kind-kubeconfig', variable: 'KUBECONFIG')]) { body() }
  }
}

// Run body with AWS credentials from the Jenkins "AWS Credentials" entry.
def withAws(Closure body) {
  withCredentials([aws(credentialsId: params.AWS_CREDENTIALS_ID,
                       accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                       secretKeyVariable: 'AWS_SECRET_ACCESS_KEY')]) {
    withEnv(["AWS_REGION=${params.AWS_REGION}", "AWS_DEFAULT_REGION=${params.AWS_REGION}"]) { body() }
  }
}

pipeline {
  agent any

  options {
    timestamps()
    ansiColor('xterm')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timeout(time: 30, unit: 'MINUTES')
  }

  triggers {
    // Picks up new commits on the mounted repo (or GitHub) within ~2 minutes.
    pollSCM('H/2 * * * *')
  }

  parameters {
    choice(name: 'DEPLOY_TARGET', choices: ['local', 'aws'],
           description: 'local = kind + localhost:5001 registry. aws = EKS + ECR (see docs/aws-mode.md).')
    string(name: 'AWS_REGION', defaultValue: 'us-east-1', description: 'AWS mode only.')
    string(name: 'EKS_CLUSTER_NAME', defaultValue: 'shipstream', description: 'AWS mode only.')
    string(name: 'AWS_CREDENTIALS_ID', defaultValue: 'aws-jenkins',
           description: 'AWS mode only. ID of the Jenkins "AWS Credentials" entry.')
    booleanParam(name: 'SIMULATE_SMOKE_FAILURE', defaultValue: false,
                 description: 'Demo: make the smoke test expect the wrong version so the Rollback stage runs.')
  }

  environment {
    APP_NAME         = 'orders-api'
    APP_DIR          = 'orders-api'
    CHART_DIR        = 'helm/orders-api'
    HELM_RELEASE     = 'orders-api'
    K8S_NAMESPACE    = 'shipstream'
    LOCAL_REGISTRY   = 'localhost:5001'
    // Jenkins sits on the "kind" Docker network, so it reaches the ingress on the
    // control-plane node by container name. The Host header selects the Ingress rule.
    LOCAL_SMOKE_URL  = 'http://shipstream-control-plane'
    LOCAL_SMOKE_HOST = 'orders.local'
    PIP_CACHE_DIR    = "${JENKINS_HOME}/.cache/pip"
    // Per-build docker config so an ECR login never lingers in jenkins_home.
    DOCKER_CONFIG    = "${WORKSPACE}/.docker"
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.GIT_SHORT = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
          env.IMAGE_TAG = "${env.GIT_SHORT}-${env.BUILD_NUMBER}"

          if (params.DEPLOY_TARGET == 'aws') {
            withAws {
              env.AWS_ACCOUNT_ID = sh(script: 'aws sts get-caller-identity --query Account --output text',
                                      returnStdout: true).trim()
            }
            env.REGISTRY = "${env.AWS_ACCOUNT_ID}.dkr.ecr.${params.AWS_REGION}.amazonaws.com"
            env.VALUES_FILE = "${env.CHART_DIR}/values-aws.yaml"
            // The Jenkins IAM principal only has namespace-scoped access on EKS;
            // the namespace is created once by an admin (docs/aws-mode.md).
            env.CREATE_NAMESPACE = 'false'
          } else {
            env.REGISTRY = env.LOCAL_REGISTRY
            env.VALUES_FILE = ''
            env.CREATE_NAMESPACE = 'true'
          }
          env.IMAGE_REPOSITORY = "${env.REGISTRY}/${env.APP_NAME}"
          env.IMAGE = "${env.IMAGE_REPOSITORY}:${env.IMAGE_TAG}"
          currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.IMAGE_TAG} -> ${params.DEPLOY_TARGET}"
        }
        sh 'mkdir -p reports && echo "Will build $IMAGE"'
      }
    }

    stage('Lint') {
      steps {
        dir(env.APP_DIR) {
          sh '''
            python3 -m venv .venv
            . .venv/bin/activate
            pip install -q -r requirements-dev.txt
            flake8 --tee --output-file=../reports/flake8.txt .
          '''
        }
        sh 'helm lint "$CHART_DIR" --strict'
      }
    }

    stage('Unit Test') {
      steps {
        dir(env.APP_DIR) {
          sh '. .venv/bin/activate && pytest --junitxml=../reports/junit.xml'
        }
      }
      post {
        always { junit allowEmptyResults: true, testResults: 'reports/junit.xml' }
      }
    }

    stage('Build Image') {
      steps {
        sh '''
          docker build --pull \
            --build-arg APP_VERSION="$IMAGE_TAG" \
            --label org.opencontainers.image.revision="$GIT_COMMIT" \
            -t "$IMAGE" "$APP_DIR"
          docker image ls "$IMAGE_REPOSITORY"
        '''
      }
    }

    stage('Trivy Scan') {
      steps {
        sh '''
          # Full HIGH+CRITICAL report for the record; never fails the build.
          trivy image --no-progress --severity HIGH,CRITICAL \
            --format table --output reports/trivy.txt "$IMAGE"
          # Gate: any CRITICAL with a fix available fails the build. Accepted
          # exceptions go in .trivyignore (with a reason and an expiry date).
          trivy image --no-progress --severity CRITICAL --ignore-unfixed \
            --ignorefile .trivyignore --exit-code 1 "$IMAGE"
        '''
      }
    }

    stage('Push') {
      steps {
        script {
          if (params.DEPLOY_TARGET == 'aws') {
            withAws {
              sh 'aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"'
            }
          }
        }
        sh 'docker push "$IMAGE"'
      }
    }

    stage('Helm Deploy') {
      steps {
        // From here on, any failure must end in a rollback. catchError marks the build
        // failed but lets the pipeline continue so the Rollback stage can run.
        script { env.ROLLBACK_NEEDED = 'true' }
        catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
          script {
            withCluster { sh 'bash scripts/ci/helm-deploy.sh' }
            env.DEPLOYED = 'true'
          }
        }
      }
    }

    stage('Smoke Test') {
      when { environment name: 'DEPLOYED', value: 'true' }
      steps {
        catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
          script {
            withCluster {
              def baseUrl = env.LOCAL_SMOKE_URL
              def hostHeader = env.LOCAL_SMOKE_HOST
              if (params.DEPLOY_TARGET == 'aws') {
                def lb = sh(returnStdout: true, script: '''
                  kubectl -n ingress-nginx get svc ingress-nginx-controller \
                    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
                ''').trim()
                baseUrl = "http://${lb}"
                hostHeader = ''
              }
              def expected = params.SIMULATE_SMOKE_FAILURE ? 'simulated-wrong-version' : env.IMAGE_TAG
              withEnv(["BASE_URL=${baseUrl}", "HOST_HEADER=${hostHeader}", "EXPECTED_VERSION=${expected}"]) {
                sh 'bash scripts/ci/smoke-test.sh'
              }
            }
            env.ROLLBACK_NEEDED = 'false'
          }
        }
      }
    }

    stage('Rollback') {
      when { environment name: 'ROLLBACK_NEEDED', value: 'true' }
      steps {
        script {
          withCluster { sh 'bash scripts/ci/rollback.sh' }
        }
        echo "Deploy of ${env.IMAGE_TAG} failed and was rolled back. See the Helm Deploy / Smoke Test logs."
      }
    }
  }

  post {
    success {
      echo "Deployed ${env.IMAGE} to ${params.DEPLOY_TARGET}."
    }
    always {
      archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
      // The image now lives in the registry; drop the local copy so the host disk doesn't fill up.
      sh 'if [ -n "$IMAGE" ]; then docker image rm "$IMAGE" >/dev/null 2>&1 || true; fi'
    }
    cleanup {
      cleanWs(deleteDirs: true, notFailBuild: true)
    }
  }
}
