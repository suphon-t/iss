import SwiftUI
import AppKit

private struct TitlebarTransparentConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.titlebarAppearsTransparent = true
            view.window?.titlebarSeparatorStyle = .none
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
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
                title: "Behavior",
                systemImage: "gearshape.fill",
                buttons: [
                    .init(label: "Grant Accessibility…", systemImage: "checkmark.shield", style: .secondary, action: requestPermission),
                ]
            )

            generalCard

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
        .background(TitlebarTransparentConfigurator().frame(width: 0, height: 0))
        .onAppear {
            // The window is on screen — make sure the Dock icon is showing.
            NSApp.setActivationPolicy(.regular)
            model.refreshStatus()
            startPolling()
        }
        .onDisappear { stopPolling() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1")
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
                    label: "Accessibility",
                    value: model.accessibilityGranted ? "Granted" : "Missing",
                    state: model.accessibilityGranted ? .ok : .error
                )
                statusRow(
                    label: "Launch at Login",
                    value: model.launchAtLoginEnabled ? "Enabled" : "Disabled",
                    state: model.launchAtLoginEnabled ? .ok : .neutral
                )
                statusRow(
                    label: "CLI",
                    value: model.cliInstalled ? "Installed" : "Not installed",
                    state: model.cliInstalled ? .ok : .neutral
                )
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var generalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "power")
                    .foregroundStyle(.secondary)
                Text("General")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            settingToggle(
                title: "Launch at Login",
                subtitle: "Start ISSApp automatically when you sign in.",
                isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { setLaunchAtLogin($0) }
                )
            )

            Divider()

            settingToggle(
                title: "Show Menu Bar Item",
                subtitle: "Display the ISS icon in the menu bar.",
                isOn: $model.showMenuBarItem
            )
        }
        .padding(14)
        .background(cardBackground)
    }

    private func settingToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(NSColor.controlBackgroundColor))
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
        .background(cardBackground)
    }

    @ViewBuilder
    private func actionButton(_ btn: ActionButton) -> some View {
        switch btn.style {
        case .primary:
            Button(action: btn.action) {
                Label(btn.label, systemImage: btn.systemImage)
            }
            .buttonStyle(.borderedProminent)
        case .secondary:
            Button(action: btn.action) {
                Label(btn.label, systemImage: btn.systemImage)
            }
            .buttonStyle(.bordered)
        case .destructive:
            Button(role: .destructive, action: btn.action) {
                Label(btn.label, systemImage: btn.systemImage)
            }
            .buttonStyle(.bordered)
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

    private func statusRow(label: String, value: String, state: StatusState) -> some View {
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
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
                model.refreshStatus()
                if model.accessibilityGranted {
                    model.startMonitoringIfPossible()
                }
            }
        }
    }

    private func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Actions

    private func requestPermission() {
        model.requestAccessibilityPermission()
        if model.accessibilityGranted {
            setMessage("Accessibility granted.", kind: .success)
        } else {
            setMessage("Approve ISSApp in Privacy & Security › Accessibility.", kind: .warning)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try model.setLaunchAtLogin(enabled)
            setMessage(enabled ? "ISSApp will launch at login." : "Launch at login disabled.", kind: .info)
        } catch {
            setMessage("Could not update Login Items: \(error.localizedDescription)", kind: .error)
        }
    }

    private func switchSpace(_ direction: SpaceDirection) {
        if !model.accessibilityGranted {
            setMessage("Grant Accessibility first.", kind: .warning)
            return
        }
        if model.switchSpace(direction) {
            setMessage(direction == .left ? "Switched left." : "Switched right.", kind: .success)
        } else {
            let edge = direction == .left ? "leftmost" : "rightmost"
            setMessage("Already at the \(edge) space.", kind: .info)
        }
    }

    private func installCLI() {
        Task { @MainActor in
            do {
                try await CLIInstaller.install()
                model.refreshStatus()
                setMessage("CLI installed at \(ISSConstants.cliInstallPath)", kind: .success)
            } catch {
                setMessage("CLI install failed: \(error.localizedDescription)", kind: .error)
            }
        }
    }

    private func uninstallCLI() {
        Task { @MainActor in
            do {
                try await CLIInstaller.uninstall()
                model.refreshStatus()
                setMessage("CLI removed from \(ISSConstants.cliInstallDirectory).", kind: .info)
            } catch {
                setMessage("CLI uninstall failed: \(error.localizedDescription)", kind: .error)
            }
        }
    }

    private func setMessage(_ text: String, kind: MessageKind) {
        message = text
        messageKind = kind
    }
}
