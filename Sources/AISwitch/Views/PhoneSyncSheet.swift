import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct PhoneSyncSheet: View {
    @EnvironmentObject private var store: AccountStore
    @ObservedObject private var sync: RemoteSync
    @Environment(\.dismiss) private var dismiss
    @State private var serverAddress = ""
    @State private var pushSecret = ""
    @State private var pairingLink: URL?
    @State private var qrImage: NSImage?
    @State private var isWorking = false
    @State private var message: String?

    init(sync: RemoteSync) {
        self.sync = sync
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                AppMark(size: 32)
                Spacer()
                IconButton(symbol: "xmark", help: "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(sync.isConfigured ? "Your limits, on your phone." : "Connect a sync server.")
                    .font(.system(size: 25, weight: .semibold))
                    .tracking(-0.7)
                    .foregroundStyle(AppPalette.ink)
                Text(sync.isConfigured
                     ? "This Mac sends account usage and short-lived access tokens to your server. Refresh tokens never leave this Mac."
                     : "Deploy the server in the Server folder, then enter its address and push secret.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if sync.isConfigured {
                connected
            } else {
                connectForm
            }

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(AppPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28)
        .frame(width: 442)
        .fixedSize(horizontal: false, vertical: true)
        .background(AppPalette.canvas)
        .onAppear {
            serverAddress = sync.settings?.serverURL.absoluteString ?? ""
        }
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledField("Server address") {
                TextField("https://aiswitch.example.com", text: $serverAddress)
            }
            labeledField("Push secret") {
                SecureField("AISWITCH_PUSH_SECRET from the server", text: $pushSecret)
            }
            Button {
                connect()
            } label: {
                HStack(spacing: 8) {
                    if isWorking { ProgressView().controlSize(.mini).tint(.white) }
                    Text(isWorking ? "Connecting…" : "Connect and push")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AppButtonStyle(prominent: true))
            .disabled(isWorking || serverAddress.isEmpty || pushSecret.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack").foregroundStyle(AppPalette.secondaryInk)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sync.settings?.serverURL.host ?? "").font(.system(size: 12, weight: .semibold))
                    Text(statusLine).font(.system(size: 10)).foregroundStyle(sync.lastError == nil ? AppPalette.secondaryInk : AppPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Push now", isWorking: sync.isPushing) {
                    Task { await store.pushToSync() }
                }
            }
            .padding(12)
            .surface(radius: 10)

            if let qrImage, let pairingLink {
                VStack(spacing: 10) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .padding(10)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(AppPalette.line) }
                    Text("Scan with your phone's camera. Each code is a separate read-only pairing.")
                        .font(.system(size: 10))
                        .foregroundStyle(AppPalette.secondaryInk)
                        .multilineTextAlignment(.center)
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pairingLink.absoluteString, forType: .string)
                    }
                    .buttonStyle(AppButtonStyle(compact: true))
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await showPairingCode() }
                } label: {
                    HStack(spacing: 6) {
                        if isWorking { ProgressView().controlSize(.mini).tint(.white) }
                        Label(qrImage == nil ? "Show QR code" : "New QR code", systemImage: "qrcode")
                    }
                }
                .buttonStyle(AppButtonStyle(prominent: true))
                .disabled(isWorking)
                Button("Unpair all phones") { Task { await revoke() } }
                    .buttonStyle(AppButtonStyle())
                    .disabled(isWorking)
                Spacer()
                Button("Disconnect") {
                    sync.disconnect()
                    qrImage = nil
                    pairingLink = nil
                    message = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.secondaryInk)
                .font(.system(size: 11))
            }
        }
    }

    private var statusLine: String {
        if let error = sync.lastError { return error }
        if let at = sync.lastPushAt { return "Last push \(at.formatted(date: .omitted, time: .shortened))" }
        return "Connected. Pushes after each usage refresh."
    }

    private func labeledField(_ title: String, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionCaption(title: title)
            field()
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .surface(radius: 7)
        }
    }

    private func connect() {
        guard let url = URL(string: serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = "Enter the server address as https://host."
            return
        }
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                try sync.configure(serverURL: url, pushSecret: pushSecret)
                await store.pushToSync()
                if let error = sync.lastError {
                    sync.disconnect()
                    message = error
                } else {
                    pushSecret = ""
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func showPairingCode() async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let link = try await sync.createViewerLink()
            pairingLink = link
            qrImage = Self.qrCode(for: link.absoluteString)
        } catch {
            message = error.localizedDescription
        }
    }

    private func revoke() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await sync.revokeViewers()
            qrImage = nil
            pairingLink = nil
            message = "All phones were unpaired. Show a new QR code to pair again."
        } catch {
            message = error.localizedDescription
        }
    }

    private static func qrCode(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
