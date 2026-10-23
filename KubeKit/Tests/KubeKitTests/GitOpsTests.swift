import Foundation
import Testing
@testable import KubeKit

@Suite struct YAMLEditTests {
    let values = """
    # Tenant overrides.
    my-app:
      backend:
        replicas: 2
        env:
          LOG_LEVEL: DEBUG   # noisy on purpose
          APP_NAME: "ACME Test"
      ui:
        env: {}
    other: 1
    """

    @Test func readsNestedEntries() {
        let yaml = YAMLEdit(values)
        #expect(yaml.entries(["my-app", "backend", "env"]).map(\.key) == ["LOG_LEVEL", "APP_NAME"])
        #expect(yaml.entries(["my-app", "backend", "env"])[1].value == "ACME Test")
        #expect(yaml.entries(["my-app", "backend", "env"])[0].value == "DEBUG")
        #expect(yaml.mappingPaths(named: "env") == [["my-app", "backend", "env"], ["my-app", "ui", "env"]])
    }

    @Test func replacesValueKeepingQuotesAndComment() {
        var yaml = YAMLEdit(values)
        yaml.set(["my-app", "backend", "env"], key: "LOG_LEVEL", value: "INFO")
        yaml.set(["my-app", "backend", "env"], key: "APP_NAME", value: "ACME")
        #expect(yaml.text.contains("      LOG_LEVEL: INFO # noisy on purpose"))
        #expect(yaml.text.contains("      APP_NAME: \"ACME\""))
        #expect(yaml.text.contains("# Tenant overrides."))
    }

    @Test func addsKeyAtEndOfBlockWithFileIndent() {
        var yaml = YAMLEdit(values)
        yaml.set(["my-app", "backend", "env"], key: "APP_FLAG", value: "true")
        let lines = yaml.text.components(separatedBy: "\n")
        let i = lines.firstIndex(of: "      APP_FLAG: \"true\"")
        #expect(i == 7)
        #expect(lines[8] == "  ui:")
    }

    @Test func expandsEmptyFlowMapAndCreatesMissingParents() {
        var yaml = YAMLEdit(values)
        yaml.set(["my-app", "ui", "env"], key: "API_URL", value: "https://x")
        #expect(yaml.text.contains("  ui:\n    env:\n      API_URL: https://x"))
        var fresh = YAMLEdit("# empty\n")
        fresh.set(["demo-ops", "backend", "env"], key: "A", value: "1")
        #expect(fresh.text == "# empty\ndemo-ops:\n  backend:\n    env:\n      A: \"1\"\n")
    }

    @Test func skipsKeysInsideListsAndBlockScalars() {
        let yaml = YAMLEdit("""
        app:
          env:
          - name: A
            value: x
          script: |
            echo: hi
            other: 1
          image:
            tag: "1.2"
        """)
        let paths = yaml.scan().map { $0.path.joined(separator: ".") }
        #expect(paths == ["app", "app.env", "app.script", "app.image", "app.image.tag"])
        #expect(yaml.entry(["app", "env"])?.kind == .list)
        #expect(yaml.entry(["app", "script"])?.kind == .scalar)
    }

    @Test func setsLiteralsAndReplacesBlocks() {
        var yaml = YAMLEdit("a:\n  replicas: 2\n  name: \"x\"\n  list:\n  - 1\n  - 2\nb: 1\n")
        yaml.setLiteral(["a"], key: "replicas", literal: YAMLEdit.literal(from: "3", previous: "2"))
        yaml.setLiteral(["a"], key: "name", literal: YAMLEdit.literal(from: "7", previous: "\"x\""))
        yaml.setLiteral(["a"], key: "list", literal: "[]")
        #expect(yaml.text == "a:\n  replicas: 3\n  name: \"7\"\n  list: []\nb: 1\n")
        #expect(YAMLEdit.literal(from: "a: b", previous: nil) == "\"a: b\"")
        #expect(YAMLEdit.literal(from: "true", previous: nil) == "true")
    }

    @Test func removesKey() {
        var yaml = YAMLEdit(values)
        yaml.remove(["my-app", "backend", "env"], key: "LOG_LEVEL")
        #expect(!yaml.text.contains("LOG_LEVEL"))
        #expect(yaml.entries(["my-app", "backend", "env"]).map(\.key) == ["APP_NAME"])
    }
}

@Suite struct HelmValuesTests {
    func app() throws -> ArgoApplication {
        let json = #"""
        {"kind": "Application", "metadata": {"name": "demo-ops-app-tst", "namespace": "argocd",
          "ownerReferences": [{"kind": "ApplicationSet", "name": "demo-ops-application-set"}]},
         "spec": {"sources": [
           {"repoURL": "git://example/gitops.git", "targetRevision": "main", "ref": "values"},
           {"repoURL": "git://example/gitops.git", "targetRevision": "main", "path": "charts/demo-ops",
            "helm": {"valueFiles": ["$values/defaults/demo-ops-app.yaml", "$values/clusters/c1/demo-ops/values.yaml",
                                    "$values/clients/acme/tst/demo-ops-app.yaml"],
                     "values": "demo-ops:\n  backend:\n    env:\n      APP_SCHEMA: acme_tst\n"}}]},
         "status": {"sync": {"status": "Synced", "revisions": ["abc123", "abc123"]}, "health": {"status": "Healthy"}}}
        """#
        return ArgoApplication(KubeObject(try JSONValue.parse(Data(json.utf8))))
    }

    func repo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kubekit-gitops-\(UUID().uuidString)")
        let files = [
            "charts/demo-ops/values.yaml": "demo-ops:\n  backend:\n    env: {}\n",
            "defaults/demo-ops-app.yaml": "demo-ops:\n  backend:\n    env:\n      LOG_LEVEL: INFO\n      SHARED: base\n",
            "clusters/c1/demo-ops/values.yaml": "demo-ops:\n  backend:\n    env:\n      CLUSTER: c1\n",
            "clients/acme/tst/demo-ops-app.yaml": "demo-ops:\n  backend:\n    env:\n      LOG_LEVEL: DEBUG\n",
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func resolvesLayersFromValueRefs() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        let layers = HelmValues.layers(for: try app()) { _ in root }
        #expect(layers.map(\.title) == ["charts/demo-ops/values.yaml", "defaults/demo-ops-app.yaml", "clusters/c1/demo-ops/values.yaml",
                                        "clients/acme/tst/demo-ops-app.yaml", "Inline values (ApplicationSet demo-ops-application-set)"])
        #expect(layers.allSatisfy { $0.exists })
    }

    @Test func mergesTreeAndPicksEditTargets() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        let layers = HelmValues.layers(for: try app()) { _ in root }
        let nodes = Dictionary(uniqueKeysWithValues: HelmValues.flatten(HelmValues.tree(layers)).map { ($0.dottedPath, $0) })
        let level = try #require(nodes["demo-ops.backend.env.LOG_LEVEL"])
        #expect(level.value == "DEBUG" && level.layer == 3 && level.definedIn == [1, 3])
        #expect(nodes["demo-ops.backend.env.APP_SCHEMA"]?.layer == 4)
        #expect(nodes["demo-ops.backend.env"]?.kind == .mapping)
        // Specific layer edited in place; shared default gets a tenant override; new keys go to the tenant file.
        let env = ["demo-ops", "backend", "env"]
        #expect(HelmValues.targetLayer(for: env + ["CLUSTER"], in: layers) == 2)
        #expect(HelmValues.targetLayer(for: env + ["SHARED"], in: layers) == 3)
        #expect(HelmValues.targetLayer(for: ["demo-ops", "backend", "replicas"], in: layers) == 3)
        #expect(HelmValues.targetLayer(for: env + ["APP_SCHEMA"], in: layers) == nil)
    }

    @Test func laterScalarOrListReplacesEarlierValue() {
        let layers = [
            ValueLayer(origin: .valueFile, title: "a", file: nil, exists: true, text: "x:\n  tags:\n  - a\n  - b\n  sub:\n    k: 1\n"),
            ValueLayer(origin: .valueFile, title: "b", file: nil, exists: true, text: "x:\n  tags: [c]\n  sub: null\n"),
        ]
        let nodes = Dictionary(uniqueKeysWithValues: HelmValues.flatten(HelmValues.tree(layers)).map { ($0.dottedPath, $0) })
        #expect(nodes["x.tags"]?.value == "[c]" && nodes["x.tags"]?.layer == 1)
        #expect(nodes["x.sub.k"] == nil && nodes["x.sub"]?.value == "null")
    }

    @Test func detectsDeployedRevision() throws {
        let app = try app()
        #expect(app.hasDeployed("abc123"))
        #expect(!app.hasDeployed("def456"))
    }
}

@Suite struct GitRepoTests {
    @Test func comparesRepoURLs() {
        #expect(GitRepo.sameRepo("https://github.com/org/repo.git", "git@github.com:org/repo"))
        #expect(GitRepo.sameRepo("https://user:token@github.com/org/repo/", "ssh://git@github.com/org/repo.git"))
        #expect(!GitRepo.sameRepo("https://github.com/org/repo", "https://github.com/org/other"))
        #expect(GitRepo.githubSlug("git@github.com:example-org/gitops.git") == "example-org/gitops")
    }
}
