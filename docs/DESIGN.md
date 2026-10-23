# KubeUI — design notes

A native macOS app (SwiftUI + AppKit where SwiftUI falls short) for browsing Kubernetes
clusters k9s-style, with a Finder-like file browser for pod filesystems.

## How we talk to the cluster

| Option | Auth (EKS `aws` exec plugin, OIDC, client certs) | exec / file copy | Effort |
|---|---|---|---|
| Native REST client (URLSession) | exec plugins easy, PEM client certs are painful (`SecIdentity` needs keychain import) | WebSocket `v5.channel.k8s.io`; stdin close only on 1.30+ servers | high |
| [SwiftKube](https://github.com/swiftkube/client) (NIO/AsyncHTTPClient) | no exec-plugin auth → no EKS | no exec support | medium, blocked |
| `kubectl proxy` + URLSession | via kubectl | exec is blocked by default; unblocking exposes an unauthenticated local port | low, unsafe |
| **Shell out to `kubectl`** | identical to the user's terminal | `kubectl exec -i` handles stdin EOF on every server version | low |

**Decision:** `kubectl` subprocesses, behind the `KubeKit` package so the transport can be swapped
for a native client later without touching the UI.

- Lists use one long-lived `kubectl get -o json --watch --output-watch-events` per view, so there is
  no polling and no per-refresh process spawn. The watcher restarts with backoff when the server
  closes the watch.
- The app never mutates kubeconfig (no `use-context`); every command passes `--context` and `-n`.
- GUI apps don't inherit the shell `PATH`, so the login shell environment is captured once at startup
  (needed for `kubectl` *and* for exec plugins such as `aws`).
- The app is not sandboxed (it must run `kubectl` and read `~/.kube`); it is meant for direct
  distribution, not the App Store.

## Pod file browser

Same mechanism as `kubectl cp`, so it needs `sh` and `tar` in the container (plus `stat`, with an
`ls` fallback, for listing).

- **List:** `sh -c 'cd -- "$1" && stat -c "%F/%s/%Y/%A/%U/%G/%n" -- * .[!.]* ..?*'`. `/` is the field
  separator because it can't occur in a file name. Works with GNU coreutils and BusyBox.
- **Upload (drag & drop):** the app writes a tar stream itself (`TarWriter`, ustar + pax for long
  names/large files) straight into `kubectl exec -i … -- tar -xf - -C <dir>`. Writing tar ourselves
  gives byte-accurate progress, cancellation, and no macOS `._*` AppleDouble files. `.DS_Store` is skipped.
- **Download / drag out to Finder:** `kubectl exec … -- tar -cf - -C <parent> <name>` piped into the
  local `/usr/bin/tar -x`, driven by an `NSFilePromiseProvider` so Finder gets a real file promise.
- The list is an `NSOutlineView` (wrapped for SwiftUI): SwiftUI `Table` only reports an insertion
  index for drops and can't vend file promises, while Finder-like behaviour needs expandable folders,
  "drop into this folder" and drag-out.

## UI layout

Modelled on Xcode's workspace window: a navigator on the left, the main content in the middle,
a context-following inspector on the right, and a bottom area for output.

- **Sidebar:** Finder-style list of resource kinds.
- **Content:** sortable, live `Table` of the selected kind. The toolbar has the context and namespace
  pickers and a search field.
- **Inspector (⌥⌘I):** follows the selection and shows metadata, containers, labels and annotations.
- **Bottom panel (⇧⌘Y):** like Xcode's debug area, a pane under the list with a drag handle; its height is
  remembered. Logs, Files, YAML and Describe open as tabs, and opening the same item again reuses its
  tab. Each tab's model outlives tab switches, so log streams and transfers keep running.
  - **Logs:** follows Xcode's console, with output on top and a bottom bar holding the filter field
    and output options. Lines are syntax-highlighted.
  - **Files:** Finder's list view in an `NSOutlineView`. Folders expand in place and are listed
    lazily on first expand. A back/forward/up bar sits above and a path bar below.
- Shell opens Terminal.app with `kubectl exec -it`.

Destructive actions (delete, scale, restart, deleting pod files) always confirm and name the context.

## Not yet / next

- Port-forwarding, edit-and-apply YAML, CRDs (generic resource discovery via `kubectl api-resources`).
- Ephemeral debug containers for distroless images (no shell → no file browsing today).
- Native REST transport for lists/watches if `kubectl` process count ever becomes a problem.
