# KubeUI

A native macOS app for working with Kubernetes clusters. It browses resources k9s-style, has a
Finder-style file browser for pods with drag & drop, and layers Argo CD and your GitOps repo on
top, so a config change goes from edit to running pods in one window.

![An Argo CD application mid-rollout](https://raw.githubusercontent.com/wiki/zoltantarcsay/KubeUI/images/argo-rollout.png)

- **Cluster browser:** live resource lists, actions (logs, shell, YAML, describe, scale,
  restart, delete), and an inspector with container image details.
- **Bottom panel:** tabs like Xcode's debug area for Finder-style pod files with drag & drop,
  highlighted logs, terminal shells, and YAML.
- **Argo CD and GitOps:** Helm values merged across their layers and edited in your clone, then
  commit, push and follow the rollout to new pods.

Documentation and screenshots are in the [wiki](https://github.com/zoltantarcsay/KubeUI/wiki):
[Features](https://github.com/zoltantarcsay/KubeUI/wiki/Features),
[Argo CD and GitOps](https://github.com/zoltantarcsay/KubeUI/wiki/Argo-CD-and-GitOps),
[Local Playground](https://github.com/zoltantarcsay/KubeUI/wiki/Local-Playground),
[Development](https://github.com/zoltantarcsay/KubeUI/wiki/Development) and
[Design](https://github.com/zoltantarcsay/KubeUI/wiki/Design).

## Quick start

Requires macOS 15+, Xcode 26+ and `kubectl`. Open `KubeUI.xcodeproj` and press ⌘R, or:

```bash
xcodebuild -project KubeUI.xcodeproj -scheme KubeUI -derivedDataPath build/DerivedData build
```

KubeUI uses your kubeconfig as-is and never changes its current context.

To try it safely, the [Local Playground](https://github.com/zoltantarcsay/KubeUI/wiki/Local-Playground)
page sets up a kind cluster with Argo CD and a GitOps repo.

## Tests

```bash
cd KubeKit && swift test
```
