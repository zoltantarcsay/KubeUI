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
| `scripts/make-icon.swift` | Draws the app icon into `KubeUI/Assets.xcassets`; rerun after changing it. |
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

## Argo CD and GitOps

When the cluster serves Argo CD's API, the sidebar gains an **Argo CD** section. Double-click an
application to see it as one pipeline: **Source** (your clone) → **Argo CD** (sync) → **Cluster**
(health, pods).

- **Link your clone once per repo URL**, from the banner above Applications or the app's Source
  card. KubeUI uses your own `git`, credentials and SSH setup, and checks the clone's origin.
- **Values** shows the app's Helm values merged across its layers, whatever the chart's structure.
  The layers are the chart's `values.yaml`, then each resolved `valueFiles` entry in order, then
  inline values from the ApplicationSet. Every key shows the layer that wins it. Search finds keys
  and values anywhere in the tree.
  - Edit or add any scalar. Typed values are written as YAML, so `3` stays a number. Only the
    changed lines are rewritten, keeping comments and formatting.
  - Edits go where they're safe by default: the file that already sets the key when it's tenant or
    cluster specific, otherwise the most specific file, so a shared `defaults/` value gets an
    override instead of changing every tenant.
  - Keys pinned inline by an ApplicationSet are locked.
  - Double-click a layer to edit its whole file in the bottom panel, with YAML highlighting. Use this
    for lists and multi-line values.
- **Changes** shows the diff. **Commit & Push** pushes to the tracked branch, asks Argo CD to
  refresh, and follows the rollout until new pods are ready. **Push as PR…** pushes a branch and
  opens GitHub's PR page; tracking then waits for the merge.
- **Resources** lists what Argo CD manages, with live readiness and pods. Right-click a pod for logs
  or files.

### Local playground

`scripts/kind-gitops-demo/setup.sh <clone dir>` adds Argo CD, an in-cluster git server and an
ApplicationSet shaped like a typical ApplicationSet-based GitOps repo (defaults → clusters → clients value files)
to the kind cluster, and clones the repo to `<clone dir>`. Keep its port-forward running while you push.

Copying files needs `sh` and `tar` in the container, as `kubectl cp` does. Plain files can still
be uploaded without `tar`. Distroless images aren't supported yet.

## Debug hooks

Debug builds read these environment variables, used for scripted UI checks:

- `KUBEUI_SNAPSHOT_DIR=<dir>` writes a PNG and a view-tree dump of every window every 2 seconds.
- `KUBEUI_OPEN=files:<namespace>/<pod>,logs:<namespace>/<pod>` opens those panel tabs at launch.
- `KUBEUI_EXPAND=/etc,/usr` expands those folders in the last opened Files tab.
- `KUBEUI_OPEN=app:<namespace>/<application>` opens an Argo CD application. `KUBEUI_VALUE_SET=a.b.KEY=VALUE`
  then edits its values, and `KUBEUI_PUSH=1` commits and pushes. `KUBEUI_APP_SECTION=Changes` picks the
  section shown first, and `KUBEUI_OPEN_LAYER=<n>` opens value layer n in the editor.
