#!/bin/sh
# Sets up an Argo CD + GitOps playground in the kind cluster created per the README:
# Argo CD, an in-cluster git server, a seeded repo shaped like a typical ApplicationSet-based GitOps repo,
# and an ApplicationSet generating two apps. Usage: setup.sh <local clone dir>
set -e
CTX=kind-kubeui-dev
HERE=$(cd "$(dirname "$0")" && pwd)
CLONE=${1:?usage: setup.sh <local clone dir>}

kubectl --context $CTX create namespace argocd 2>/dev/null || true
kubectl --context $CTX apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml >/dev/null
kubectl --context $CTX apply -f "$HERE/gitserver.yaml"
kubectl --context $CTX -n gitops rollout status deploy/gitserver --timeout=180s
kubectl --context $CTX -n argocd rollout status deploy/argocd-repo-server --timeout=300s

# Your clone talks to the git server through this port-forward; keep it running while you push.
kubectl --context $CTX -n gitops port-forward svc/gitserver 9418:9418 >/dev/null 2>&1 &
echo "port-forward pid $!"
sleep 2

if [ ! -d "$CLONE/.git" ]; then
  git clone git://localhost:9418/gitops.git "$CLONE"
  git -C "$CLONE" switch -q -c main 2>/dev/null || true
  cp -R "$HERE/repo/." "$CLONE/"
  git -C "$CLONE" add -A
  git -C "$CLONE" commit -qm "Seed demo gitops repo"
  git -C "$CLONE" push -q -u origin main
fi

kubectl --context $CTX apply -f "$HERE/appset.yaml"
echo "Done. Argo CD apps: kubectl --context $CTX -n argocd get applications"
