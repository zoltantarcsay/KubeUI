# KubeUI

Native macOS Kubernetes client (SwiftUI + AppKit), with Argo CD and GitOps editing layered on top.
User docs live in the [wiki](https://github.com/zoltantarcsay/KubeUI/wiki), a separate repo
(`KubeUI.wiki.git`); the README is only an overview.

## Layout

- `KubeKit/`: Swift package with no UI.
  - kubectl runner (`Kubectl`, `ProcessRunner`), watches (`KubeClient`)
  - resource columns (`ResourceKind`), pod files and tar (`PodFileSystem`, `TarWriter`)
  - Argo CD (`ArgoCD`, `HelmValues`), YAML editing (`YAMLEdit`), git (`GitRepo`)
  - All logic that can be unit-tested goes here.
- `KubeUI/`: the app. `Cluster/` is the main window, `Panels/` the bottom panel tabs, `Files/`,
  `Logs/`, `Shell/` and `Argo/` are features, and `Support/` holds shared views and debug hooks.
  The folder is synchronized in the Xcode project, so new files need no project edits.
- `scripts/kind-gitops-demo/`: the local Argo CD + GitOps playground.

## Build and test

```bash
xcodebuild -project KubeUI.xcodeproj -scheme KubeUI -configuration Debug -derivedDataPath build/DerivedData build
```

```bash
cd KubeKit && swift test
```

- Also build `-configuration Release` before committing. `#if DEBUG` code has broken Release before.
- Integration tests need `KUBEUI_TEST_CONTEXT=kind-kubeui-dev KUBEUI_TEST_POD=demo/alpine`.

## Conventions

- **Transport:** everything goes through `kubectl` subprocesses (see the wiki's Design page for why).
  - Never change the kubeconfig (no `use-context`). Every command passes `--context`.
  - Build arguments with `KubeClient.args`: it puts scope flags after the subcommand and before `--`.
- **Concurrency:** the app target uses Swift 6 with `MainActor` as the default isolation. AppKit
  callbacks that arrive off the main thread (file promises, SwiftTerm delegates) must be
  `nonisolated` and hop back to the main actor.
- **YAML:** edits to GitOps files go through `YAMLEdit`, which rewrites only the changed lines.
  Never round-trip YAML through a parser and serializer; it would reformat users' files.
- **Argo CD:** use the live `Application` (its resolved `helm.valueFiles`), not ApplicationSet
  templates. Assume no chart structure: values are arbitrary YAML.
- **Dependencies:** SwiftTerm is the only one, pinned to `upToNextMinor` 1.11.x, because 1.12+
  adds a Metal renderer that needs the separately downloaded Metal Toolchain. Avoid adding more.
- **Comments:** keep them to one line, explaining why rather than what.

## Testing against clusters

- Only use the kind context `kind-kubeui-dev`. Never run commands against other contexts in the
  kubeconfig; they may be production.
- Launch the app for checks with a kind-only kubeconfig (`kind get kubeconfig --name kubeui-dev`)
  and `-ApplePersistenceIgnoreState YES`.
- Stop only the instance you started, by its PID. Never `pkill KubeUI` or quit it by bundle ID:
  the user may be running their own copy from Xcode.
- Screen recording isn't available, so verify UI with the debug hooks listed on the wiki's
  Development page (`KUBEUI_SNAPSHOT_DIR`, `KUBEUI_OPEN`, …). Window snapshots don't capture glass
  areas (sidebar, inspector) or terminal text exactly.

## Publishing

- This is a public repo. Use only neutral examples (`example-org/gitops`, `123456789012`, `my-app`,
  `acme`), never names, account IDs or repos from real employers or clusters.
- Commit as `Zoltan Tarcsay <6171404+zoltantarcsay@users.noreply.github.com>` (set in the repo's
  local git config).
- When features change, update the wiki pages and retake affected screenshots from the kind
  playground. Screenshots live in the wiki repo's `images/`.
