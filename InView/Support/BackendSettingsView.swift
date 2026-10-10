import AccessCore
import SwiftUI

struct BackendSettingsView: View {
    @State private var address = AppConfig.backendAddress
    @State private var accessToken = AppConfig.backendToken ?? ""
    @State private var connectionStatus: String?
    @State private var isChecking = false
    @State private var connectionTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server address (optional)", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !address.isEmpty {
                        SecureField("Access token (if required)", text: $accessToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Use on-device processing") { address = "" }
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
                    Text("Leave blank to process scans on this device. If set, scans are sent to this server.")
                }
            }
            .navigationTitle("Scan processing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if AppConfig.setBackendToken(accessToken) {
                            AppConfig.setBackendAddress(address)
                            dismiss()
                        } else {
                            connectionStatus = "Could not securely save the access token."
                        }
                    }
                    .disabled(!address.isEmpty && AppConfig.validatedBackendURL(address) == nil)
                }
            }
            .onChange(of: accessToken) { _, _ in
                connectionTask?.cancel()
                isChecking = false
                connectionStatus = nil
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
        let testedToken = accessToken
        let token = testedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        isChecking = true
        connectionStatus = nil
        connectionTask = Task {
            let status: String
            do {
                try await BackendClient(baseURL: url, accessToken: token).checkHealth()
                status = "Connected to the scan processing server."
            } catch is CancellationError {
                return
            } catch {
                status = error.localizedDescription
            }
            guard !Task.isCancelled, address == testedAddress, accessToken == testedToken else { return }
            connectionStatus = status
            isChecking = false
        }
    }
}
