import AppKit
import Combine
import ServiceManagement

enum ProcessFilter: String, CaseIterable, Identifiable {
    case mine = "My processes"
    case favorites = "Favorites"
    case all = "All processes"

    var id: Self { self }
}

@MainActor
final class PortStore: ObservableObject {
    @Published var processes: [PortProcess] = []
    @Published var refreshing = false
    @Published var lastRefresh: Date?
    @Published var error: String?
    @Published var notice: String?
    @Published var search = ""
    @Published var processFilter: ProcessFilter = .mine
    @Published var pendingStops: [ProcessIdentity: Date] = [:]
    @Published var favoriteText: String {
        didSet { defaults.set(favoriteText, forKey: "favoritePorts") }
    }
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginMessage: String?
    var panelVisible = false
    private var polling: Task<Void, Never>?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, startMonitoring: Bool = true) {
        self.defaults = defaults
        favoriteText = defaults.string(forKey: "favoritePorts") ?? "3000, 3001, 4000, 5000, 5173, 8000, 8080, 8888"
        if startMonitoring { start() }
    }

    var favorites: Set<Int> {
        Set(favoriteText.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .compactMap { Int($0) }.filter { (1...65535).contains($0) })
    }

    var favoriteInputValid: Bool {
        favoriteText.split(whereSeparator: { $0 == "," || $0.isWhitespace }).allSatisfy {
            if let port = Int($0) { return (1...65535).contains(port) }
            return false
        }
    }

    var visibleProcesses: [PortProcess] {
        processes.filter { process in
            let listener = process.listener
            let matchesSearch = search.isEmpty ||
                "\(listener.command) \(listener.pid) \(listener.addresses.joined(separator: " ")) \(process.executable ?? "")"
                .localizedCaseInsensitiveContains(search)
            let matchesFilter: Bool
            switch processFilter {
            case .mine: matchesFilter = listener.uid == getuid() && process.protectionReason == nil
            case .favorites: matchesFilter = !favorites.isDisjoint(with: listener.ports)
            case .all: matchesFilter = true
            }
            return matchesFilter && matchesSearch
        }.sorted {
            let leftFavorite = !favorites.isDisjoint(with: $0.listener.ports)
            let rightFavorite = !favorites.isDisjoint(with: $1.listener.ports)
            if leftFavorite != rightFavorite { return leftFavorite }
            return ($0.listener.ports.first ?? 0, $0.id) < ($1.listener.ports.first ?? 0, $1.id)
        }
    }

    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let seconds: UInt64 = self?.panelVisible == true ? 2 : 10
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let result = try await Task.detached(priority: .utility) { try ProcessMonitor.scan() }.value
            processes = result
            let identities = Set(result.compactMap(\.identity))
            let completed = pendingStops.keys.filter { !identities.contains($0) }
            if !completed.isEmpty { notice = "Process no longer appears in the listener list." }
            pendingStops = pendingStops.filter { identities.contains($0.key) }
            lastRefresh = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop(_ process: PortProcess, force: Bool) async {
        guard let identity = process.identity else {
            error = MonitorError.changed.localizedDescription
            return
        }
        do {
            try ProcessMonitor.stop(identity, force: force)
            pendingStops[identity] = Date()
            notice = force ? "Force kill sent. Checking process…" : "Stop requested. Force Kill is available if it stays alive."
            try? await Task.sleep(nanoseconds: 350_000_000)
            await refresh()
        } catch {
            self.error = error.localizedDescription
            await refreshAfterFailure()
        }
    }

    private func refreshAfterFailure() async {
        let message = error
        await refresh()
        error = message
    }

    func updateLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = SMAppService.mainApp.status == .requiresApproval
                ? "Allow PortKeeper in System Settings → General → Login Items."
                : nil
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = "Couldn’t update login setting: \(error.localizedDescription)"
        }
    }
}

