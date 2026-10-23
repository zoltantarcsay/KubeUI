# KubeUI

A native macOS app for working with Kubernetes clusters: k9s-style resource browsing and a
Finder-style file browser for pods, with drag & drop upload and download.

Requires macOS 15+, Xcode 26+ and `kubectl` on your machine. Design notes and the reasoning
behind using `kubectl` as the transport are in [docs/DESIGN.md](docs/DESIGN.md).

## Layout

| Path | What |
|---|---|
| `KubeKit/` | Swift package, no UI: kubectl runner, watch streaming, resource columns, tar writer, pod file operations. Unit and integration tests. |
| `KubeUI/` | The app (SwiftUI, plus AppKit for the file table and text views). |
| `KubeUI.xcodeproj` | Xcode project; the `KubeUI/` folder is synchronized, so new files are picked up automatically. |

## Build and run

Open `KubeUI.xcodeproj` in Xcode and press ⌘R, or from the command line:

```bash
xcodebuild -project KubeUI.xcodeproj -scheme KubeUI -derivedDataPath build/DerivedData build
```

```bash
open build/DerivedData/Build/Products/Debug/KubeUI.app
```

KubeUI uses your normal kubeconfig and never changes its current context. A new window opens
on your kubeconfig's current context, so switch the toolbar's context picker to a test cluster
before trying destructive actions.

## Tests

```bash
cd KubeKit && swift test
```

Integration tests (upload, list, download, watch) run only when you point them at a cluster
and a pod with `sh` and `tar`:

```bash
cd KubeKit && KUBEUI_TEST_CONTEXT=kind-kubeui-dev KUBEUI_TEST_POD=demo/alpine swift test
```

### Local test cluster

```bash
brew install kind && kind create cluster --name kubeui-dev
```

`kind create cluster` switches your kubeconfig's current context to the new cluster; switch back
with `kubectl config use-context <previous>` if you rely on it in a terminal.

```bash
kubectl --context kind-kubeui-dev create namespace demo
```

```bash
kubectl --context kind-kubeui-dev -n demo run alpine --image=alpine:3.20 --command -- sleep infinity
```

```bash
kubectl --context kind-kubeui-dev -n demo run debian --image=debian:bookworm-slim --command -- sleep infinity
```

## Using it

- **Cluster window:** pick a context and namespace in the toolbar and a resource kind in the sidebar.
  Lists update live. ⌥⌘I shows the inspector, ⌘R reloads, ⌘N opens another window.
- **Right-click a row** for Browse Files, Show Logs, Open Shell (Terminal), Show YAML, Describe,
  Scale, Restart, Copy Name and Delete.
- **Double-click a pod** to open its files. Double-click other resources to open their YAML.
- **Files window:**
  - Drag files or folders from Finder onto the list to upload them to the folder you're viewing,
    or onto a folder row to upload into that folder.
  - Drag items out to Finder to download them.
  - Double-click a file to download it to a temp folder and open it.
  - ⌘[ / ⌘] go back and forward, ⌘↑ goes to the enclosing folder, ⌘↓ opens, ⇧⌘G goes to a path,
    ⇧⌘N creates a new folder and ⌘⌫ deletes.
  - Pods with several containers have a container picker in the toolbar.

Copying files needs `sh` and `tar` in the container, as `kubectl cp` does. Plain files can still
be uploaded without `tar`. Distroless images aren't supported yet.

## Debug hooks

Debug builds read two environment variables, used for scripted UI checks:

- `KUBEUI_SNAPSHOT_DIR=<dir>` writes a PNG and a view-tree dump of every window every 2 seconds.
- `KUBEUI_OPEN=files:<namespace>/<pod>` (or `logs:…`) opens that window at launch.
