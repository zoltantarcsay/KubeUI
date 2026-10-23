#!/bin/sh
# Sets up an Argo CD + GitOps playground in the kind cluster from the wiki's Local Playground page:
# Argo CD, an in-cluster git server, a seeded repo shaped like a typical ApplicationSet-based GitOps repo,
# and an ApplicationSet generating two apps. Usage: setup.sh <local clone dir>
# Safe to re-run; an existing repo or clone is reused, not re-seeded.
set -e
CTX=kind-kubeui-dev
HERE=$(cd "$(dirname "$0")" && pwd)
CLONE=${1:?usage: setup.sh <local clone dir>}
# Argo CD reads the repo in-cluster at this URL; the clone uses the same URL as its origin.
REPO_URL=git://gitserver.gitops.svc.cluster.local/gitops.git

kubectl --context $CTX create namespace argocd 2>/dev/null || true
kubectl --context $CTX apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml >/dev/null
kubectl --context $CTX apply -f "$HERE/gitserver.yaml"
kubectl --context $CTX -n gitops rollout status deploy/gitserver --timeout=180s
kubectl --context $CTX -n argocd rollout status deploy/argocd-repo-server --timeout=300s

# Your clone reaches the git server through this port-forward; keep it running while you push.
if nc -z localhost 9418 2>/dev/null; then
  echo "port 9418 already forwarded"
else
  kubectl --context $CTX -n gitops port-forward svc/gitserver 9418:9418 >/dev/null 2>&1 &
  echo "port-forward pid $! (kill it when done)"
  sleep 2
fi

if [ ! -d "$CLONE/.git" ]; then
  git clone -q git://localhost:9418/gitops.git "$CLONE"
  # Same origin URL as Argo CD, rewritten to the port-forward for fetch and push.
  git -C "$CLONE" remote set-url origin "$REPO_URL"
  git -C "$CLONE" config url."git://localhost:9418/".insteadOf "git://gitserver.gitops.svc.cluster.local/"
  if ! git -C "$CLONE" rev-parse -q --verify HEAD >/dev/null; then
    git -C "$CLONE" switch -q -c main
    cp -R "$HERE/repo/." "$CLONE/"
    git -C "$CLONE" add -A
    git -C "$CLONE" commit -qm "Seed demo gitops repo"
    git -C "$CLONE" push -q -u origin main
  fi
fi

kubectl --context $CTX apply -f "$HERE/appset.yaml"
echo "Done. Link $CLONE in KubeUI. Argo CD apps: kubectl --context $CTX -n argocd get applications"
