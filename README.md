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
- **Double-click a pod** to browse its files. Double-click other resources to show their YAML.
- **Bottom panel:** logs, files, YAML and describe open as tabs in a panel under the list, like
  Xcode's debug area. ⇧⌘Y shows or hides it. Tabs keep running in the background, so logs keep
  streaming while you look at something else.
- **Logs:** the bar at the bottom has a filter field, the container and line-count pickers, and
  Follow, Previous, Wrap and Clear (⌘K).
- **Files:**
  - Folders expand in place like Finder's list view: click the triangle or double-click the folder.
    ⌘↓ makes the selected folder the root, and ⌘↑ goes to the enclosing folder.
  - Drag files or folders from Finder onto the list to upload them into the root, or onto a
    folder row to upload into that folder.
  - Drag items out to Finder to download them.
  - Double-click a file to download it to a temp folder and open it.
  - ⌘[ / ⌘] go back and forward, ⇧⌘G goes to a path, ⇧⌘N creates a new folder and ⌘⌫ deletes.
  - Pods with several containers, native sidecars included, have a container picker.

Copying files needs `sh` and `tar` in the container, as `kubectl cp` does. Plain files can still
be uploaded without `tar`. Distroless images aren't supported yet.

## Debug hooks

Debug builds read these environment variables, used for scripted UI checks:

- `KUBEUI_SNAPSHOT_DIR=<dir>` writes a PNG and a view-tree dump of every window every 2 seconds.
- `KUBEUI_OPEN=files:<namespace>/<pod>,logs:<namespace>/<pod>` opens those panel tabs at launch.
- `KUBEUI_EXPAND=/etc,/usr` expands those folders in the last opened Files tab.
