# AWS mode: ECR + EKS

Local mode (kind + `localhost:5001`) is the default and costs nothing. AWS mode runs the same Jenkinsfile, the same Helm chart, and the same smoke test against a real cloud. Only the registry, the cluster, and the credentials change.

> **Cost warning.** The EKS control plane, two `t3.medium` nodes and one NLB are all billed while they run. Do the [cleanup](#8-clean-up) as soon as you have your screenshots.

## What changes

| Concern | Local mode | AWS mode |
|---|---|---|
| Image registry | `registry:2` container at `localhost:5001` | ECR repo `<account>.dkr.ecr.<region>.amazonaws.com/orders-api` |
| Registry auth | none (plain HTTP on localhost) | `aws ecr get-login-password \| docker login` in the **Push** stage |
| Cluster | kind (1 control-plane + 2 workers) | EKS with a managed node group (2 × t3.medium) |
| Kubeconfig in Jenkins | `kind-kubeconfig` secret-file credential | Built per build by `aws eks update-kubeconfig` |
| Cluster RBAC for Jenkins | full admin (kind's default kubeconfig) | EKS access entry: **Edit** on `shipstream`, **View** on `ingress-nginx` |
| Namespace | created by `helm --create-namespace` | created once by an admin; Jenkins can't create namespaces |
| Ingress entry point | kind hostPort 80 → ingress-nginx, `Host: orders.local` | ingress-nginx `LoadBalancer` service → NLB DNS name, no host rule |
| Helm values | `values.yaml` | `values.yaml` + `values-aws.yaml` |
| How nodes pull images | containerd `hosts.toml` mirror → `kind-registry:5000` | node IAM role has `AmazonEC2ContainerRegistryReadOnly` |

In the Jenkinsfile, the `DEPLOY_TARGET` parameter switches modes. The `withAws` and `withCluster` helpers at the top hold the only mode-specific code.

## Prerequisites

- An AWS account and an admin profile for the one-time setup (`aws configure --profile admin`)
- `aws` CLI v2, `eksctl`, `kubectl`, `helm`
- The local Jenkins from the main README, already running

```bash
export AWS_PROFILE=admin
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

## 1. Create the ECR repository

```bash
aws ecr create-repository \
  --repository-name orders-api \
  --image-tag-mutability IMMUTABLE \
  --image-scanning-configuration scanOnPush=true \
  --region "$AWS_REGION"

# Keep only the last 20 images
aws ecr put-lifecycle-policy --repository-name orders-api --region "$AWS_REGION" \
  --lifecycle-policy-text '{"rules":[{"rulePriority":1,"description":"keep last 20","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":20},"action":{"type":"expire"}}]}'
```

`IMMUTABLE` tags work because every build pushes a unique `<git-sha>-<build-number>` tag. Nobody can overwrite an image that is already deployed.

## 2. Create the IAM identity Jenkins uses

Jenkins runs on your laptop, not on AWS, so it has no instance role to inherit. Give it a dedicated IAM user with a single inline policy.

```bash
aws iam create-user --user-name shipstream-jenkins

sed -e "s/<REGION>/$AWS_REGION/g" -e "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" \
  aws/iam-policy-jenkins.json > /tmp/jenkins-policy.json

aws iam put-user-policy --user-name shipstream-jenkins \
  --policy-name shipstream-jenkins-ci \
  --policy-document file:///tmp/jenkins-policy.json

aws iam create-access-key --user-name shipstream-jenkins   # note AccessKeyId + SecretAccessKey
```

### IAM permissions and why each one is needed

| Permission | Resource | Used by | Why |
|---|---|---|---|
| `ecr:GetAuthorizationToken` | `*` (can't be scoped) | Push | Returns the short-lived password for `docker login` |
| `ecr:BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage` | `repository/orders-api` | Push | The layer-upload protocol behind `docker push` |
| `ecr:BatchGetImage`, `GetDownloadUrlForLayer` | `repository/orders-api` | Push | `docker push` reads existing manifests and layers to skip re-uploads |
| `ecr:DescribeImages`, `DescribeRepositories` | `repository/orders-api` | debugging | Lets you check from Jenkins what was pushed |
| `eks:DescribeCluster` | `cluster/shipstream` | Helm Deploy, Smoke Test, Rollback | `aws eks update-kubeconfig` needs the endpoint and CA |
| `sts:GetCallerIdentity` | (always allowed) | Checkout | Finds the account ID that forms the ECR hostname |

IAM decides only *which AWS APIs* Jenkins can call. Its permissions *inside* Kubernetes come from the EKS access entry in step 3. With IAM alone, Jenkins can fetch a kubeconfig, but every `kubectl` call returns `Forbidden`.

**Hardening, optional but recommended.** Create a role `shipstream-jenkins-deployer` with the policy above, and leave the user with only `sts:AssumeRole` on that role. Put the role ARN in the credential's *IAM Role To Use* field. Builds then run on one-hour session credentials, and a leaked access key is useless on its own. If Jenkins ever moves onto AWS (EC2/EKS), drop the user entirely and use an instance role or IRSA / EKS Pod Identity.

## 3. Create the EKS cluster

```bash
sed -i "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" aws/eksctl-cluster.yaml   # don't commit your account ID
eksctl create cluster -f aws/eksctl-cluster.yaml                 # ~15-20 minutes
kubectl get nodes
```

The `accessConfig.accessEntries` block in [aws/eksctl-cluster.yaml](../aws/eksctl-cluster.yaml) grants the `shipstream-jenkins` user:

- `AmazonEKSEditPolicy` scoped to namespace `shipstream`, so Helm can create Deployments, Services, Ingresses and PDBs there, plus the Secrets that hold Helm's release history
- `AmazonEKSViewPolicy` scoped to namespace `ingress-nginx`, so the smoke test can read the NLB hostname

If the cluster already exists, add the same thing by hand:

```bash
aws eks create-access-entry --cluster-name shipstream \
  --principal-arn arn:aws:iam::$ACCOUNT_ID:user/shipstream-jenkins
aws eks associate-access-policy --cluster-name shipstream \
  --principal-arn arn:aws:iam::$ACCOUNT_ID:user/shipstream-jenkins \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy \
  --access-scope type=namespace,namespaces=shipstream
aws eks associate-access-policy --cluster-name shipstream \
  --principal-arn arn:aws:iam::$ACCOUNT_ID:user/shipstream-jenkins \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy \
  --access-scope type=namespace,namespaces=ingress-nginx
```

## 4. Cluster add-ons and the namespace (run once, as admin)

```bash
# ingress-nginx behind an AWS Network Load Balancer
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx --version 4.15.1 \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb

kubectl -n ingress-nginx get svc ingress-nginx-controller -w   # wait for EXTERNAL-IP (a DNS name)

# The app namespace, with the same Pod Security label as local
kubectl apply -f k8s/namespace.yaml
```

> ingress-nginx was retired upstream in March 2026 and gets no further fixes. It's used here to match the local setup. On a real EKS cluster you'd use the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) (an ALB per Ingress) or a Gateway API implementation. Switching only changes `ingress.className` and `ingress.annotations` in `values-aws.yaml`.

## 5. Add the AWS credential to Jenkins

**UI:** *Manage Jenkins → Credentials → System → Global credentials → Add Credentials*

| Field | Value |
|---|---|
| Kind | **AWS Credentials** (from the `aws-credentials` plugin, already in `jenkins/plugins.txt`) |
| ID | `aws-jenkins` (must match the `AWS_CREDENTIALS_ID` parameter) |
| Access Key ID / Secret Access Key | from `aws iam create-access-key` |
| IAM Role To Use | optional, the deployer role ARN if you set up role assumption |

**As code instead:** uncomment the `aws:` block in [jenkins/casc.yaml](../jenkins/casc.yaml), then:

```bash
export AWS_ACCESS_KEY_ID=AKIA...  AWS_SECRET_ACCESS_KEY=...
# add both variables to the jenkins service's environment: in docker-compose.yml, then
docker compose -f jenkins/docker-compose.yml up -d
```

Never commit the keys. Jenkins stores the credential encrypted in `jenkins_home`, and the pipeline only exposes it inside `withCredentials`, so it is masked in logs.

## 6. Run the pipeline in AWS mode

*shipstream-orders-api → Build with Parameters*

| Parameter | Value |
|---|---|
| `DEPLOY_TARGET` | `aws` |
| `AWS_REGION` | `us-east-1` |
| `EKS_CLUSTER_NAME` | `shipstream` |
| `AWS_CREDENTIALS_ID` | `aws-jenkins` |

What each stage does differently:

- **Checkout**: calls `aws sts get-caller-identity` to build the ECR hostname, and selects `values-aws.yaml`
- **Lint / Unit Test / Build Image / Trivy Scan**: identical to local mode
- **Push**: runs `docker login` to ECR with a 12-hour token, then `docker push`
- **Helm Deploy**: runs `aws eks update-kubeconfig` into the workspace, then the same `helm upgrade --install` without `--create-namespace`
- **Smoke Test**: reads the NLB hostname from the `ingress-nginx-controller` service and calls it with no Host header
- **Rollback**: same `helm rollback`, against EKS

## 7. Verify by hand

```bash
LB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$LB/health
kubectl -n shipstream get pods -o wide
helm history orders-api -n shipstream
aws ecr describe-images --repository-name orders-api --query 'imageDetails[].imageTags' --output table
```

## 8. Clean up

```bash
helm uninstall orders-api -n shipstream
helm uninstall ingress-nginx -n ingress-nginx      # deletes the NLB; do this BEFORE deleting the cluster
eksctl delete cluster -f aws/eksctl-cluster.yaml
aws ecr delete-repository --repository-name orders-api --force
aws iam delete-access-key --user-name shipstream-jenkins --access-key-id <AccessKeyId>
aws iam delete-user-policy --user-name shipstream-jenkins --policy-name shipstream-jenkins-ci
aws iam delete-user --user-name shipstream-jenkins
```

Uninstall ingress-nginx first. Otherwise the NLB and its security groups can be orphaned, which blocks VPC deletion and makes `eksctl delete cluster` hang.
