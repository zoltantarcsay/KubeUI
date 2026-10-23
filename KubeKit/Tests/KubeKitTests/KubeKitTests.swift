import Foundation
import Testing
@testable import KubeKit

@Suite struct JSONStreamSplitterTests {
    @Test func splitsChunkedPrettyPrintedObjects() throws {
        let stream = #"{"a": {"b": "}{"}}"# + "\n" + #"{ "c": [1, {"d": "\"}"}] }"#
        var splitter = JSONStreamSplitter()
        var objects: [Data] = []
        for byte in Data(stream.utf8) { objects += splitter.feed(Data([byte])) }
        #expect(objects.count == 2)
        #expect(try JSONValue.parse(objects[0])["a.b"].string == "}{")
        #expect(try JSONValue.parse(objects[1])["c"][1]["d"].string == "\"}")
    }
}

@Suite struct ResourceTests {
    @Test func agesLookLikeKubectl() {
        #expect(formatAge(42) == "42s")
        #expect(formatAge(185) == "3m5s")
        #expect(formatAge(3600) == "60m")
        #expect(formatAge(5 * 3600 + 120) == "5h2m")
        #expect(formatAge(3 * 86400) == "3d")
    }

    @Test func podStatusPrefersWaitingReason() throws {
        let pod = try JSONValue.parse(Data(#"""
        {"status": {"phase": "Running", "containerStatuses": [
          {"state": {"waiting": {"reason": "CrashLoopBackOff"}}}]}}
        """#.utf8))
        #expect(PodStatus.reason(pod) == "CrashLoopBackOff")
    }

    @Test func runningSidecarDoesNotLookLikeInit() throws {
        let pod = try JSONValue.parse(Data(#"""
        {"spec": {"initContainers": [{"name": "proxy", "restartPolicy": "Always"}], "containers": [{"name": "app"}]},
         "status": {"phase": "Running",
           "initContainerStatuses": [{"name": "proxy", "started": true, "ready": true, "restartCount": 1, "state": {"running": {}}}],
           "containerStatuses": [{"name": "app", "ready": true, "restartCount": 2, "state": {"running": {}}}]}}
        """#.utf8))
        #expect(PodStatus.reason(pod) == "Running")
        #expect(PodStatus.readiness(pod) == (2, 2))
        #expect(ResourceKind.pods.columns.first { $0.title == "Restarts" }!.value(KubeObject(pod), Date()).text == "3")
    }

    @Test func pendingInitContainerShowsProgress() throws {
        let pod = try JSONValue.parse(Data(#"""
        {"spec": {"initContainers": [{"name": "migrate"}, {"name": "proxy", "restartPolicy": "Always"}], "containers": [{"name": "app"}]},
         "status": {"phase": "Pending",
           "initContainerStatuses": [{"name": "migrate", "state": {"running": {}}}, {"name": "proxy", "state": {"waiting": {"reason": "PodInitializing"}}}]}}
        """#.utf8))
        #expect(PodStatus.reason(pod) == "Init:0/2")
    }
}

@Suite struct ListingTests {
    @Test func parsesStatOutput() {
        let output = """
        directory/4096/1700000000/drwxr-xr-x/root/root/etc
        regular file/12/1700000000/-rw-r--r--/app/app/a b|c.txt
        symbolic link/7/1700000000/lrwxrwxrwx/root/root/lib
        __KUBEUI_LINKDIRS__
        lib

        """
        let files = PodFileSystem.parseListing(output)
        #expect(files.map(\.name) == ["etc", "a b|c.txt", "lib"])
        #expect(files[1].size == 12 && files[1].owner == "app")
        #expect(files[2].kind == .symlink && files[2].isNavigable)
    }

    @Test func parsesLsFallback() {
        let files = PodFileSystem.parseListing("__KUBEUI_NOSTAT__\n./\n../\nbin/\nfile\n__KUBEUI_LINKDIRS__\n")
        #expect(files.map(\.name) == ["bin", "file"])
        #expect(files[0].isDirectory)
    }
}

@Suite struct TarWriterTests {
    @Test func roundTripsThroughBsdtar() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("kubekit-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src/folder")
        let deep = src.appendingPathComponent(String(repeating: "d", count: 90) + "/" + String(repeating: "e", count: 90))
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let longName = String(repeating: "x", count: 150) + ".txt"
        try Data("hello".utf8).write(to: src.appendingPathComponent("small.txt"))
        try Data(repeating: 7, count: 70_000).write(to: deep.appendingPathComponent(longName))
        try Data("junk".utf8).write(to: src.appendingPathComponent(".DS_Store"))
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("link").path, withDestinationPath: "small.txt")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent("small.txt").path)

        let archive = root.appendingPathComponent("out.tar")
        fm.createFile(atPath: archive.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archive)
        var reported: Int64 = 0
        try TarWriter.write(try TarWriter.entries(for: [src]), to: { try handle.write(contentsOf: $0) }, progress: { reported = $0 })
        try handle.close()
        #expect(reported == 70_005)

        let out = root.appendingPathComponent("out")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", archive.path, "-C", out.path]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)

        let extracted = out.appendingPathComponent("folder")
        #expect(try String(contentsOf: extracted.appendingPathComponent("small.txt"), encoding: .utf8) == "hello")
        let mode = try fm.attributesOfItem(atPath: extracted.appendingPathComponent("small.txt").path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(try fm.destinationOfSymbolicLink(atPath: extracted.appendingPathComponent("link").path) == "small.txt")
        #expect(!fm.fileExists(atPath: extracted.appendingPathComponent(".DS_Store").path))
        let deepOut = extracted.appendingPathComponent(String(repeating: "d", count: 90) + "/" + String(repeating: "e", count: 90) + "/" + longName)
        #expect(try Data(contentsOf: deepOut) == Data(repeating: 7, count: 70_000))
    }

    @Test func paxRecordLengthCountsItself() {
        let record = TarWriter.paxRecord(("path", String(repeating: "a", count: 95)))
        #expect(record.utf8.count == Int(record.prefix { $0 != " " })!)
    }
}

/// Runs against a real cluster only when `KUBEUI_TEST_CONTEXT` is set, e.g.
/// `KUBEUI_TEST_CONTEXT=kind-kubeui-dev KUBEUI_TEST_POD=demo/alpine swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KUBEUI_TEST_CONTEXT"] != nil))
struct ClusterIntegrationTests {
    let context = ProcessInfo.processInfo.environment["KUBEUI_TEST_CONTEXT"] ?? ""
    let podPath = (ProcessInfo.processInfo.environment["KUBEUI_TEST_POD"] ?? "demo/alpine").split(separator: "/").map(String.init)

    @Test func uploadListDownload() async throws {
        let kubectl = try await Kubectl.resolve()
        let fs = PodFileSystem(kubectl: kubectl, pod: PodRef(context: context, namespace: podPath[0], pod: podPath[1], containers: []), container: nil)
        let fm = FileManager.default
        let local = fm.temporaryDirectory.appendingPathComponent("kubekit-it-\(UUID().uuidString)")
        let folder = local.appendingPathComponent("upload-me")
        try fm.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 3_000_000).write(to: folder.appendingPathComponent("nested/big.bin"))
        try Data("hi".utf8).write(to: folder.appendingPathComponent("hi.txt"))
        defer { try? fm.removeItem(at: local) }

        let remoteDir = "/tmp/kubekit-it"
        try await fs.makeDirectory(remoteDir)
        try await fs.upload([folder], to: remoteDir) { _, _ in }
        let listing = try await fs.list(remoteDir + "/upload-me")
        #expect(Set(listing.map(\.name)) == ["nested", "hi.txt"])

        let back = try await fs.download(remoteDir + "/upload-me", to: local.appendingPathComponent("downloaded"))
        #expect(try Data(contentsOf: back.appendingPathComponent("nested/big.bin")).count == 3_000_000)
        try await fs.remove([remoteDir])
    }

    @Test func watchDeliversSnapshot() async throws {
        let kubectl = try await Kubectl.resolve()
        let client = KubeClient(kubectl: kubectl, context: context)
        for try await update in client.watch(.pods, namespace: podPath[0]) {
            guard case .snapshot(let pods) = update else { continue }
            #expect(pods.contains { $0.name == podPath[1] })
            break
        }
    }
}
