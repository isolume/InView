import AccessCore
import SwiftUI

struct BackendSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("detailedScanning") private var detailedScanning = false
    @AppStorage("recordScanVideo") private var recordScanVideo = false
    @State private var address = AppConfig.backendAddress
    @State private var token = AppConfig.backendToken(for: AppConfig.backendAddress) ?? ""
    @State private var message: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Maps are built on this device.")
                    Toggle("Detailed scan", isOn: $detailedScanning)
                } footer: {
                    Text("Adds surface detail and photo colors to new scans. Uses more battery and storage.")
                }
                Section {
                    Toggle("Record video", isOn: $recordScanVideo)
                } footer: {
                    Text("Saves video with matching LiDAR measurements for 3D modeling. No audio. Uses more battery and storage; export it from Saved scans.")
                }
                Section {
                    TextField("Server address", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField(AppConfig.hasBuiltInBackendToken ? "Access token (built in; enter to override)" : "Access token",
                                text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(checking ? "Checking…" : "Save settings", action: saveSettings)
                        .disabled(checking)
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Find places")
                } footer: {
                    Text("Optional. Choose Find places during review to send this scan's photos, measurements and location to your server. You decide which suggestions to keep.")
                }
                Section {
                    NavigationLink("Saved scans") { SavedStreamUploadsView() }
                } footer: {
                    Text("View saved maps and export original scan data. Earlier scan evidence remains available.")
                }
            }
            .onChange(of: address) { oldValue, newValue in
                if AppConfig.backendOrigin(oldValue) != AppConfig.backendOrigin(newValue) {
                    token = AppConfig.backendToken(for: newValue) ?? ""
                }
            }
            .navigationTitle("Scanning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
        }
    }

    private func saveSettings() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || AppConfig.validatedBackendURL(trimmed) != nil else {
            message = "Enter a valid server address."
            return
        }
        guard AppConfig.setBackendToken(token, for: trimmed) else {
            message = "The access token couldn't be saved. Try again."
            return
        }
        AppConfig.setBackendAddress(trimmed)
        guard let url = AppConfig.backendURL else { message = "Server disconnected."; return }
        checking = true
        Task {
            defer { checking = false }
            do {
                try await BackendClient(baseURL: url, accessToken: AppConfig.backendToken).checkHealth()
                message = "Server is ready."
            } catch { message = error.localizedDescription }
        }
    }
}
