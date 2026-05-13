import SwiftUI

struct ContentView: View {
    @State private var daemonStatus: String = DaemonServiceManager.statusDescription()
    @State private var daemonHashSummary: String = "unknown"
    @State private var daemonUpToDate: Bool = false
    @State private var daemonPath: String = ""
    @State private var daemonPermissionGranted: Bool = false
    @State private var cliInstalled: Bool = CLIInstaller.isInstalled()
    @State private var message: String = ""
    @State private var messageKind: MessageKind = .info
    @State private var refreshTimer: Timer?

    enum MessageKind {
        case info, success, warning, error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            statusCard

            actionsCard(
                title: "Daemon",
                systemImage: "gearshape.2.fill",
                buttons: [
                    .init(label: "Request Permission", systemImage: "checkmark.shield", style: .secondary, action: requestPermission),
                    .init(label: "Install / Update", systemImage: "arrow.down.circle", style: .primary, action: installDaemon),
                    .init(label: "Uninstall", systemImage: "trash", style: .destructive, action: uninstallDaemon),
                ]
            )

            actionsCard(
                title: "Quick Switch",
                systemImage: "rectangle.split.2x1",
                buttons: [
                    .init(label: "Switch Left", systemImage: "arrow.left", style: .secondary, action: { switchSpace(.left) }),
                    .init(label: "Switch Right", systemImage: "arrow.right", style: .secondary, action: { switchSpace(.right) }),
                ]
            )

            actionsCard(
                title: "Command-Line Tool",
                systemImage: "terminal",
                buttons: [
                    .init(label: "Install CLI", systemImage: "arrow.down.circle", style: .primary, action: installCLI),
                    .init(label: "Uninstall CLI", systemImage: "trash", style: .destructive, action: uninstallCLI),
                ]
            )

            messageView
        }
        .padding(20)
        .frame(width: 560)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            Task { await refreshStatus() }
            startPolling()
        }
        .onDisappear { stopPolling() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Instant Space Switcher")
                    .font(.title2).bold()
                Text("Fast, gesture-driven Space switching for macOS.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Status")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                statusRow(
                    label: "Input Permission",
                    value: daemonPermissionGranted ? "Granted" : "Missing",
                    state: daemonPermissionGranted ? .ok : .error
                )
                statusRow(
                    label: "Daemon",
                    value: daemonStatus.capitalized,
                    state: statusState(for: daemonStatus)
                )
                statusRow(
                    label: "Daemon Freshness",
                    value: daemonUpToDate ? "Up to date" : "Stale or unreachable",
                    state: daemonUpToDate ? .ok : .warning
                )
                statusRow(
                    label: "Daemon Hash",
                    value: daemonHashSummary,
                    state: daemonUpToDate ? .ok : .neutral,
                    monospaced: true
                )
                statusRow(
                    label: "CLI",
                    value: cliInstalled ? "Installed" : "Not installed",
                    state: cliInstalled ? .ok : .neutral
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private struct ActionButton: Identifiable {
        let id = UUID()
        let label: String
        let systemImage: String
        let style: Style
        let action: () -> Void

        enum Style { case primary, secondary, destructive }
    }

    private func actionsCard(title: String, systemImage: String, buttons: [ActionButton]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(buttons) { btn in
                    actionButton(btn)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func actionButton(_ btn: ActionButton) -> some View {
        switch btn.style {
        case .primary:
            Button(action: btn.action) {
                Label(btn.label, systemImage: btn.systemImage)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        case .secondary:
            Button(action: btn.action) {
                Label(btn.label, systemImage: btn.systemImage)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        case .destructive:
            Button(role: .destructive, action: btn.action) {
                Label(btn.label, systemImage: btn.systemImage)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private var messageView: some View {
        if !message.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: messageIcon)
                    .foregroundStyle(messageColor)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(messageColor.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(messageColor.opacity(0.25), lineWidth: 1)
            )
        }
    }

    // MARK: - Status row

    enum StatusState {
        case ok, warning, error, neutral

        var color: Color {
            switch self {
            case .ok: return .green
            case .warning: return .orange
            case .error: return .red
            case .neutral: return .secondary
            }
        }
    }

    private func statusRow(label: String, value: String, state: StatusState, monospaced: Bool = false) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
                .shadow(color: state.color.opacity(0.5), radius: 2)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func statusState(for status: String) -> StatusState {
        let lower = status.lowercased()
        if lower.contains("stale") { return .warning }
        if lower.contains("enabled") || lower.contains("running") { return .ok }
        if lower.contains("not") || lower.contains("disabled") || lower.contains("error") { return .error }
        return .neutral
    }

    private var messageIcon: String {
        switch messageKind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var messageColor: Color {
        switch messageKind {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    // MARK: - Polling

    private func startPolling() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                await refreshStatus()
            }
        }
    }

    private func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Actions

    private func requestPermission() {
        startPolling()
        Task {
            do {
                daemonPermissionGranted = try await XPCClient.requestDaemonAccessibilityPermission()
                if !daemonPermissionGranted {
                    setMessage("Daemon permission not granted yet. Approve in Privacy & Security › Accessibility.", kind: .warning)
                } else {
                    setMessage("Daemon permission granted.", kind: .success)
                }
            } catch {
                setMessage("Could not request daemon permission: \(error.localizedDescription)", kind: .error)
            }
        }
    }

    private func installDaemon() {
        startPolling()
        do {
            try DaemonServiceManager.installOrUpdateDaemon()
            daemonStatus = DaemonServiceManager.statusDescription()
            setMessage("Daemon installed/updated. If needed, approve in Login Items and re-grant Accessibility for the current daemon path.", kind: .success)

            Task { await refreshStatus() }
        } catch {
            daemonStatus = DaemonServiceManager.statusDescription()
            setMessage("Daemon install failed: \(error.localizedDescription)", kind: .error)
        }
    }

    private func uninstallDaemon() {
        startPolling()
        do {
            try DaemonServiceManager.unregisterDaemon()
            daemonStatus = DaemonServiceManager.statusDescription()
            setMessage("Daemon unregistered.", kind: .info)
        } catch {
            daemonStatus = DaemonServiceManager.statusDescription()
            setMessage("Daemon uninstall failed: \(error.localizedDescription)", kind: .error)
        }
    }

    private func switchSpace(_ direction: SpaceDirection) {
        Task {
            do {
                try await XPCClient.switchSpace(direction: direction)
                setMessage(direction == .left ? "Switched left." : "Switched right.", kind: .success)
            } catch {
                setMessage("Switch failed: \(error.localizedDescription)", kind: .error)
            }
        }
    }

    private func installCLI() {
        Task { @MainActor in
            do {
                try await CLIInstaller.install()
                cliInstalled = CLIInstaller.isInstalled()
                setMessage("CLI installed at /usr/local/bin/\(ISSConstants.cliExecutableName)", kind: .success)
            } catch {
                setMessage("CLI install failed: \(error.localizedDescription)", kind: .error)
            }
        }
    }

    private func uninstallCLI() {
        Task { @MainActor in
            do {
                try await CLIInstaller.uninstall()
                cliInstalled = CLIInstaller.isInstalled()
                setMessage("CLI removed from /usr/local/bin.", kind: .info)
            } catch {
                setMessage("CLI uninstall failed: \(error.localizedDescription)", kind: .error)
            }
        }
    }

    private func setMessage(_ text: String, kind: MessageKind) {
        message = text
        messageKind = kind
    }

    @MainActor
    private func refreshStatus() async {
        daemonStatus = DaemonServiceManager.statusDescription()
        let expectedPath = DaemonServiceManager.expectedDaemonExecutablePath()
        let expectedHash = DaemonServiceManager.expectedDaemonExecutableHash()

        do {
            let runtime = try await XPCClient.daemonRuntimeInfo()
            daemonPermissionGranted = runtime.accessibilityGranted
            let currentHashPrefix = runtime.binaryHash.isEmpty ? "unavailable" : String(runtime.binaryHash.prefix(12))
            let expectedHashPrefix = expectedHash.isEmpty ? "unavailable" : String(expectedHash.prefix(12))
            daemonHashSummary = "\(currentHashPrefix) (expected \(expectedHashPrefix))"
            daemonPath = runtime.executablePath
            daemonUpToDate = !runtime.binaryHash.isEmpty && !expectedHash.isEmpty && (runtime.binaryHash == expectedHash)

            if !daemonUpToDate, daemonStatus == "enabled" {
                daemonStatus = "enabled (running stale daemon binary)"
            }
        } catch {
            daemonPermissionGranted = false
            daemonHashSummary = "unreachable"
            daemonPath = ""
            daemonUpToDate = false
        }
        cliInstalled = CLIInstaller.isInstalled()

        if !daemonPath.isEmpty && !daemonUpToDate {
            let staleMsg = "Daemon binary hash mismatch. Running path: \(daemonPath). Expected path: \(expectedPath). Use Install/Update Daemon, then re-grant Accessibility for the current daemon path."
            if message.isEmpty || message.hasPrefix("Daemon binary hash mismatch.") {
                setMessage(staleMsg, kind: .warning)
            }
        }

        if daemonPermissionGranted && daemonUpToDate {
            stopPolling()
        }
    }
}
