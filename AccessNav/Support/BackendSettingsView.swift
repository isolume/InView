import AccessCore
import SwiftUI

struct BackendSettingsView: View {
    @State private var address = AppConfig.backendAddress
    @State private var connectionStatus: String?
    @State private var isChecking = false
    @State private var connectionTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://your-mac.local:3000", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
                    Text("Your scans are sent to this server to create the 3D map. It must be reachable from this device.")
                }
            }
            .navigationTitle("Scan processing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        AppConfig.setBackendAddress(address)
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
