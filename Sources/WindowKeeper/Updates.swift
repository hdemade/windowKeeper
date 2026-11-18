import Cocoa

/// Vérifie s'il existe une version plus récente parmi les publications GitHub du projet.
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        var version: String
        var name: String
        var pageURL: URL
        var downloadURL: URL?
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    static let releasesPage = URL(string: "https://github.com/hdemade/windowKeeper/releases")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/hdemade/windowKeeper/releases/latest")!
    /// Entre deux vérifications automatiques.
    private static let period: TimeInterval = 24 * 3600

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastCheck: Date?

    /// Appelé sur le fil principal quand une nouvelle version vient d'être trouvée.
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    var automatic: Bool {
        get { defaults.object(forKey: "checkUpdates") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "checkUpdates")
            objectWillChange.send()
            schedule()
        }
    }

    var available: Release? {
        if case .available(let release) = status { return release }
        return nil
    }

    init() {
        lastCheck = defaults.object(forKey: "lastUpdateCheck") as? Date
    }

    /// Lance les vérifications automatiques : peu après le démarrage, puis une fois par jour.
    func start() {
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard automatic else { return }
        let elapsed = lastCheck.map { Date().timeIntervalSince($0) } ?? .infinity
        let firstDelay = max(10, min(Self.period - elapsed, Self.period))
        timer = Timer.scheduledTimer(withTimeInterval: firstDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.check()
            self.timer = Timer.scheduledTimer(withTimeInterval: Self.period, repeats: true) { [weak self] _ in self?.check() }
        }
    }

    func check() {
        if status == .checking { return }
        status = .checking
        var request = URLRequest(url: Self.latestAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WindowKeeper/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession(configuration: .ephemeral).dataTask(with: request) { [weak self] data, response, error in
            let result = Self.parse(data: data, response: response, error: error)
            DispatchQueue.main.async { self?.finish(result) }
        }.resume()
    }

    private func finish(_ result: Result<Release, Error>) {
        let previous = available
        let now = Date()
        lastCheck = now
        defaults.set(now, forKey: "lastUpdateCheck")
        switch result {
        case .success(let release):
            if Self.compare(release.version, currentVersion) == .orderedDescending {
                status = .available(release)
                wkLog("Mise à jour disponible : \(release.version)")
            } else {
                status = .upToDate
            }
        case .failure(let error):
            // Une vérification automatique ratée ne doit pas masquer une mise à jour déjà trouvée.
            if let previous = previous {
                status = .available(previous)
            } else {
                status = .failed(error.localizedDescription)
            }
            wkLog("Vérification des mises à jour impossible : \(error.localizedDescription)")
        }
        onChange?()
    }

    /// Ouvre le téléchargement de l'image disque, ou la page de la version s'il n'y en a pas.
    func download(_ release: Release) {
        NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
    }

    // MARK: Lecture de la réponse

    private struct Payload: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
        }
        var tag_name: String
        var name: String?
        var html_url: URL
        var assets: [Asset]
    }

    private struct Failure: LocalizedError {
        var errorDescription: String?
    }

    private static func parse(data: Data?, response: URLResponse?, error: Error?) -> Result<Release, Error> {
        if let error = error { return .failure(error) }
        guard let http = response as? HTTPURLResponse, let data = data else {
            return .failure(Failure(errorDescription: "Réponse vide de GitHub."))
        }
        if http.statusCode == 404 {
            return .failure(Failure(errorDescription: "Aucune version publiée sur GitHub."))
        }
        guard http.statusCode == 200 else {
            return .failure(Failure(errorDescription: "GitHub a répondu \(http.statusCode)."))
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let version = payload.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let dmg = payload.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            return .success(Release(version: version,
                                    name: payload.name?.isEmpty == false ? payload.name! : payload.tag_name,
                                    pageURL: payload.html_url,
                                    downloadURL: dmg?.browser_download_url))
        } catch {
            return .failure(Failure(errorDescription: "Réponse de GitHub illisible."))
        }
    }

    /// Compare deux numéros de version composante par composante (« 1.1 » == « 1.1.0 » < « 1.10 »).
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
