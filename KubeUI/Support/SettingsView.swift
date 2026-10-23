import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(AppModel.kubectlPathKey) private var kubectlPath = ""

    var body: some View {
        Form {
            TextField("kubectl path", text: $kubectlPath, prompt: Text("Detect automatically"))
            LabeledContent("In use") {
                Text(app.kubectl?.executable.path ?? app.setupError ?? "Not resolved yet")
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            Button("Detect Again") { Task { await app.reset() } }
            Text("KubeUI runs kubectl with your login shell's environment, so exec auth plugins such as aws and gke-gcloud-auth-plugin work as they do in Terminal. It never changes your kubeconfig's current context.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .task { await app.ensureKubectl() }
    }
}
