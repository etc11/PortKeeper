import SwiftUI
import AppKit
import ServiceManagement

@main
struct PortKeeperApp: App {
    @StateObject private var store: PortStore
    private let settingsWindow: SettingsWindowController

    init() {
        let store = PortStore()
        _store = StateObject(wrappedValue: store)
        settingsWindow = SettingsWindowController(store: store)
    }

    var body: some Scene {
        MenuBarExtra {
            PortPanel(store: store, openSettings: settingsWindow.present)
        } label: {
            Image(systemName: "network")
                .accessibilityLabel("PortKeeper")
        }
        .menuBarExtraStyle(.window)
    }
}

struct PortPanel: View {
    @ObservedObject var store: PortStore
    let openSettings: () -> Void
    @State private var forceTarget: PortProcess?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.title2).foregroundStyle(.tint)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("PortKeeper").font(.headline)
                    Text("\(store.visibleProcesses.count) shown · \(store.processes.count) detected")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.refreshing)
                .help("Refresh ports")
                .accessibilityLabel("Refresh ports")
            }
            .padding(16)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search ports, processes, or PID", text: $store.search)
                    .textFieldStyle(.plain)
                if !store.search.isEmpty {
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(9)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)

            HStack {
                Picker("Show", selection: $store.processFilter) {
                    ForEach(ProcessFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .help("My processes hides protected services. Favorites shows favorite ports. All processes includes all detected listeners. Search applies to every view.")
            }
            .font(.caption).padding(.horizontal, 16).padding(.vertical, 12)

            Divider()
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            ScrollView {
                LazyVStack(spacing: 9) {
                    if store.visibleProcesses.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: store.lastRefresh == nil ? "antenna.radiowaves.left.and.right" : "checkmark.circle")
                                .font(.largeTitle).foregroundStyle(.secondary)
                            Text(store.lastRefresh == nil ? "Looking for listening ports…" : "No matching listeners")
                                .font(.headline)
                            Text("Start a development server, or adjust your filters.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 36)
                    }
                    ForEach(store.visibleProcesses) { process in
                        ProcessCard(process: process, store: store) { forceTarget = process }
                    }
                }.padding(12)
            }
            .frame(height: 340)

            if let notice = store.notice {
                HStack(alignment: .top) {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss status")
                }.padding(.horizontal, 14).padding(.bottom, 10)
            }
            Divider()
            HStack {
                if let date = store.lastRefresh {
                    Text("Updated \(date, style: .time)").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Scanning…").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .help("Settings").accessibilityLabel("Settings")
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }.padding(12)
        }
        .frame(width: 440)
        .background(.background)
        .onAppear {
            store.panelVisible = true
            store.start()
            Task { await store.refresh() }
        }
        .onDisappear { store.panelVisible = false }
        .alert("Force kill this process?", isPresented: Binding(
            get: { forceTarget != nil }, set: { if !$0 { forceTarget = nil } }
        ), presenting: forceTarget) { process in
            Button("Cancel", role: .cancel) { forceTarget = nil }
            Button("Force Kill", role: .destructive) {
                forceTarget = nil
                Task { await store.stop(process, force: true) }
            }
        } message: { process in
            Text("\(process.listener.command) (PID \(process.id)) will exit immediately without cleanup. All its listening ports (\(process.listener.ports.map(String.init).joined(separator: ", "))) may close.")
        }
    }
}

/// Own a regular window explicitly: menu-bar-only apps must activate themselves
/// and bring Settings forward independently of the transient menu bar panel.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let store: PortStore

    init(store: PortStore) {
        self.store = store
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "PortKeeper Settings"
            window.identifier = NSUserInterfaceItemIdentifier("PortKeeperSettings")
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: PortSettings(store: store))
            window.center()
            self.window = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ProcessCard: View {
    let process: PortProcess
    @ObservedObject var store: PortStore
    let requestForce: () -> Void

    private var pending: Bool {
        process.identity.map { store.pendingStops[$0] != nil } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(process.listener.ports.map(String.init).joined(separator: " · "))
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                    Text(process.listener.command).font(.subheadline.weight(.medium))
                }
                Spacer()
                if !store.favorites.isDisjoint(with: process.listener.ports) {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange)
                        .help("Contains a favorite port")
                }
                if let bytes = process.residentBytes {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help("Resident memory for this process, across all its ports")
                } else {
                    Text("Memory unavailable").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("PID \(String(process.id))")
                Text("·")
                Text(process.listener.uid == getuid() ? "Your process" : "UID \(process.listener.uid)")
                Spacer()
                if let reason = process.protectionReason {
                    Label("Protected", systemImage: "lock.shield")
                        .help(reason)
                        .accessibilityLabel("Protected: \(reason)")
                } else if pending {
                    Button("Force Kill…", role: .destructive, action: requestForce)
                        .help("The process has not exited yet")
                } else {
                    Button("Stop", role: .destructive) {
                        Task { await store.stop(process, force: false) }
                    }
                    .disabled(process.identity == nil || process.listener.uid != getuid() || process.id == getpid() || process.id <= 1)
                    .help("Request graceful termination of this process and all its listening ports")
                }
            }.font(.caption).foregroundStyle(.secondary)

            HStack {
                Text(process.listener.addresses.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    .help(process.listener.addresses.joined(separator: "\n"))
                Spacer()
                Menu {
                    ForEach(process.listener.ports, id: \.self) { port in
                        Button("Open http://localhost:\(port)") {
                            if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                        }
                        Button("Copy port \(port)") { copy(String(port)) }
                    }
                    Divider()
                    Button("Copy PID") { copy(String(process.id)) }
                    if let path = process.executable {
                        Button("Copy executable path") { copy(path) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Open as HTTP or copy process details")
                .accessibilityLabel("Actions for PID \(process.id)")
            }
            if let reason = process.protectionReason {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct PortSettings: View {
    @ObservedObject var store: PortStore

    var body: some View {
        Form {
            Section("Favorite ports") {
                TextField("Ports", text: $store.favoriteText, axis: .vertical)
                Text("Separate ports with commas. Favorites appear first in the list.")
                    .font(.caption).foregroundStyle(.secondary)
                if !store.favoriteInputValid {
                    Text("Use port numbers between 1 and 65535. Invalid entries are ignored.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Startup") {
                Toggle("Launch PortKeeper at login", isOn: Binding(
                    get: { store.loginEnabled }, set: { store.updateLogin($0) }
                ))
                if let message = store.loginMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Monitoring") {
                Text("macOS system executables, Apple-signed apps and services, and processes that cannot be verified are protected. Stop and Force Kill are unavailable for these processes.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("TCP listeners refresh every 2 seconds while the panel is open and every 10 seconds in the background. Memory is resident memory per process. Some protected processes may be unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Stop requests graceful termination. Force Kill becomes available if the process remains alive. Supervisors may restart stopped processes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 420)
        .onAppear { store.loginEnabled = SMAppService.mainApp.status == .enabled }
    }
}
