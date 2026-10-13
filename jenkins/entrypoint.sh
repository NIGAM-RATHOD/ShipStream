#!/bin/bash
# Give the jenkins user access to the host Docker socket, then start Jenkins as jenkins.
#
# The socket's group ID differs between hosts (Linux: the "docker" group, often 999 or 998;
# Docker Desktop: usually 0). Rather than hard-coding a GID, read it from the socket.
set -euo pipefail

SOCK=/var/run/docker.sock
if [ -S "$SOCK" ]; then
  gid="$(stat -c '%g' "$SOCK")"
  group="$(getent group "$gid" | cut -d: -f1 || true)"
  if [ -z "$group" ]; then
    group=docker-host
    groupadd --gid "$gid" "$group"
  fi
  usermod -aG "$group" jenkins
  echo "shipstream: jenkins added to group ${group} (gid ${gid}) for ${SOCK}"
else
  echo "shipstream: WARNING ${SOCK} not mounted - Docker stages will fail" >&2
fi

exec gosu jenkins /usr/bin/tini -- /usr/local/bin/jenkins.sh "$@"
