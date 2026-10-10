import AccessCore
import SwiftUI

struct BackendSettingsView: View {
    @State private var address = AppConfig.backendAddress
    @State private var continuousScanning = AppConfig.continuousScanning
    @State private var connectionStatus: String?
    @State private var isChecking = false
    @State private var connectionTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Continuous scanning", isOn: $continuousScanning)
                } footer: {
                    Text("Scan without sections. This preview saves camera and depth samples on the phone and sends them to your server for the 3D model.")
                }
                Section {
                    TextField("Server address (optional)", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !address.isEmpty {
                        Button("Clear server address") { address = "" }
                    }
                    Button("Test connection") { checkConnection() }
                        .disabled(isChecking || AppConfig.validatedBackendURL(address) == nil)
                    if isChecking {
                        HStack {
                            ProgressView()
                            Text("Checking…")
                        }
                    } else if let connectionStatus {
                        Text(connectionStatus)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Scan processing server")
                } footer: {
                    Text(continuousScanning
                         ? "Without a server, the scan stays on this phone. Connect a server to build the full 3D model."
                         : "Leave blank to process scans on this device. If set, scans are sent to this server.")
                }
                Section {
                    NavigationLink("Saved scans") { SavedStreamUploadsView() }
                }
            }
            .navigationTitle("Scan processing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        AppConfig.setBackendAddress(address)
                        AppConfig.setContinuousScanning(continuousScanning)
                        dismiss()
                    }
                    .disabled(!address.isEmpty && AppConfig.validatedBackendURL(address) == nil)
                }
            }
            .onChange(of: address) { _, _ in
                connectionTask?.cancel()
                isChecking = false
                connectionStatus = nil
            }
            .onDisappear { connectionTask?.cancel() }
        }
    }

    private func checkConnection() {
        guard let url = AppConfig.validatedBackendURL(address) else { return }
        connectionTask?.cancel()
        let testedAddress = address
        isChecking = true
        connectionStatus = nil
        connectionTask = Task {
            let status: String
            do {
                try await BackendClient(baseURL: url).checkHealth()
                status = "Connected to the scan processing server."
            } catch is CancellationError {
                return
            } catch {
                status = error.localizedDescription
            }
            guard !Task.isCancelled, address == testedAddress else { return }
            connectionStatus = status
            isChecking = false
        }
    }
}
