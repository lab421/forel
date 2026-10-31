// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421
import SwiftUI
import ForelCore

private func serverErrorDescription(_ error: Error) -> String {
    (error as? ActionError)?.message ?? error.localizedDescription
}

private func cleanupCredential(_ id: String, model: AppModel) throws {
    try model.db.withLock { db in
        guard try !db.loadUploadServers().contains(where: { $0.credentialID == id }) else { return }
        try UploadCredentials.delete(for: id)
    }
}

private struct ServerEditRequest: Identifiable {
    let id = UUID()
    let server: UploadServer?
}

struct ServersSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: ServerEditRequest?
    @State private var deleting: UploadServer?
    @State private var errorMessage = ""

    var body: some View {
        SectionLabel(title: "Servers")
        Text("Save connections for use in upload actions.")
            .font(.caption).foregroundStyle(ForelTheme.secondaryText)
        if model.uploadServers.isEmpty {
            Text("No servers saved.").foregroundStyle(ForelTheme.secondaryText)
        } else {
            GlassCard {
                VStack(spacing: 0) {
                    ForEach(model.uploadServers, id: \.id) { server in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(server.name).fontWeight(.semibold)
                                Text("\(server.protocolType.label) · \(server.username)@\(server.host)")
                                    .font(.caption).foregroundStyle(ForelTheme.secondaryText).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Edit") { editing = ServerEditRequest(server: server) }
                            Button(role: .destructive) { deleting = server } label: { Image(systemName: "trash") }
                                .help("Delete server")
                        }.padding(12)
                    }
                }
            }
        }
        Button("Add Server…") { editing = ServerEditRequest(server: nil) }
        if !errorMessage.isEmpty {
            Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
        }
        Color.clear.frame(height: 0)
            .sheet(item: $editing) { request in
                ServerEditorView(server: request.server) { errorMessage = $0 }
            }
            .alert("Delete server?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete", role: .destructive) {
                    guard let server = deleting else { return }
                    do {
                        try model.db.withLock { try $0.deleteUploadServer(id: server.id) }
                        model.reloadUploadServers()
                        do { try cleanupCredential(server.credentialID, model: model); errorMessage = "" }
                        catch { errorMessage = "Server deleted, but its unused Keychain credential could not be removed: \(serverErrorDescription(error))" }
                    } catch { errorMessage = serverErrorDescription(error) }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("Rules using this server will no longer be able to upload until you choose another server.")
            }
    }
}

private struct ServerEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let server: UploadServer?
    let reportCleanup: (String) -> Void
    @State private var name: String
    @State private var protocolType: UploadProtocol
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var identityPath: String
    @State private var password = ""
    @State private var message = ""
    @State private var testing = false
    @State private var connectionTask: Task<Void, Error>?

    init(server: UploadServer?, reportCleanup: @escaping (String) -> Void) {
        self.server = server
        self.reportCleanup = reportCleanup
        _name = State(initialValue: server?.name ?? "")
        _protocolType = State(initialValue: server?.protocolType ?? .webdavs)
        _host = State(initialValue: server?.host ?? "")
        _port = State(initialValue: server?.port.map(String.init) ?? "")
        _username = State(initialValue: server?.username ?? "")
        _identityPath = State(initialValue: server?.identityPath ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(server == nil ? "Add Server" : "Edit Server").font(.headline)
            Form {
                TextField("Name", text: $name)
                Picker("Protocol", selection: $protocolType) {
                    ForEach(UploadProtocol.allCases, id: \.self) { type in Text(type.label).tag(type) }
                }
                TextField("Host", text: $host)
                TextField("Port (optional)", text: $port)
                TextField("User name", text: $username)
                SecureField(protocolType == .sftp ? "Password or key passphrase" : "Password", text: $password)
                if protocolType == .sftp {
                    TextField("Private key path (optional)", text: $identityPath)
                    Text("The server's host key must already be trusted in your SSH known-hosts file.")
                        .font(.caption).foregroundStyle(ForelTheme.secondaryText)
                }
            }
            if server != nil { Text("Leave the password blank to keep the saved credential.").font(.caption).foregroundStyle(ForelTheme.secondaryText) }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            HStack {
                Button("Test Connection", action: testConnection).disabled(testing)
                if testing { ProgressView().controlSize(.small); Text("Connecting…").font(.caption) }
                Spacer()
                Button("Cancel") { connectionTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(testing)
            }
        }.padding(20).frame(width: 480)
            .onDisappear { connectionTask?.cancel() }
    }

    private func draft(credentialID: String) throws -> UploadServer {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ActionError("Enter a server name") }
        let portNumber: Int?
        if port.isEmpty { portNumber = nil }
        else if let value = Int(port), (1...65535).contains(value) { portNumber = value }
        else { throw ActionError("Enter a valid server port") }
        let result = UploadServer(id: server?.id ?? UUID().uuidString, name: trimmedName, protocolType: protocolType,
                                  host: host, port: portNumber, username: username,
                                  identityPath: protocolType == .sftp && !identityPath.isEmpty ? identityPath : nil,
                                  credentialID: credentialID)
        _ = try result.configuration()
        return result
    }

    private func save() {
        let newCredential = !password.isEmpty
        let id = newCredential ? UUID().uuidString : (server?.credentialID ?? UUID().uuidString)
        do {
            let value = try draft(credentialID: id)
            let configuration = try value.configuration()
            if newCredential { try UploadCredentials.save(password, for: id, configuration: configuration) }
            else if let server {
                // Loading against the draft rejects an existing secret bound to a different origin.
                do { _ = try UploadCredentials.load(for: id, configuration: configuration) }
                catch {
                    let old = try server.configuration()
                    if old.protocolType != configuration.protocolType || old.host != configuration.host ||
                       old.port != configuration.port || old.username != configuration.username {
                        throw ActionError("\(serverErrorDescription(error)) Re-enter the password for the changed server.")
                    }
                    throw error
                }
            }
            do { try model.db.withLock { try $0.saveUploadServer(value) } }
            catch {
                if newCredential {
                    do { try UploadCredentials.delete(for: id) }
                    catch let cleanupError {
                        throw ActionError("Server was not saved: \(serverErrorDescription(error)). The new Keychain credential could not be removed: \(serverErrorDescription(cleanupError))")
                    }
                }
                throw error
            }
            model.reloadUploadServers()
            if newCredential, let oldID = server?.credentialID, oldID != id {
                do { try cleanupCredential(oldID, model: model); reportCleanup("") }
                catch { reportCleanup("Server saved, but its unused Keychain credential could not be removed: \(serverErrorDescription(error))") }
            } else { reportCleanup("") }
            dismiss()
        } catch { message = serverErrorDescription(error) }
    }

    private func testConnection() {
        do {
            let value = try draft(credentialID: server?.credentialID ?? UUID().uuidString)
            let configuration = try value.configuration()
            let secret = password.isEmpty ? try UploadCredentials.load(for: value.credentialID, configuration: configuration) : password
            testing = true
            message = ""
            let task = Task.detached { try SystemUploadTransport().testConnection(configuration: configuration, password: secret) }
            connectionTask = task
            Task {
                do {
                    try await task.value
                    if !task.isCancelled { message = "Connection successful." }
                } catch { if !task.isCancelled { message = serverErrorDescription(error) } }
                connectionTask = nil
                testing = false
            }
        } catch { message = serverErrorDescription(error) }
    }
}
