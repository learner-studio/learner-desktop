import Foundation

/// Where "Open GrowthBook Dashboard" goes. GrowthBook is installed and hosted with
/// learner-server, on whichever machine that is (this Mac or another), under /growthbook/
/// of the server's own origin: so the link is the learner-server origin this app already
/// talks to. Page and API then share one origin (and that site's login).
///
/// 10-28: the menu opened http://localhost:3200 through an SSH tunnel to the remote box,
/// but that GrowthBook serves its API at https://dev.biztoolz.app/growthbook (its
/// APP_ORIGIN and API_HOST, behind that site's login): every API call from the tunnelled
/// page went cross-origin, met the login redirect, and failed ("Failed to fetch").
enum GrowthBookLink {
    /// An explicit URL (GROWTHBOOK_URL, or this defaults key) always wins.
    static let defaultsKey = "growthbook_url"

    /// - serverBase: the learner-server API this app uses (e.g. https://host/learner-api,
    ///   or a local one when learner-server runs on this Mac). nil when it is not a URL.
    static func url(serverBase: String, override: String?) -> URL? {
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty { return URL(string: o) }
        guard let base = URLComponents(string: serverBase), let scheme = base.scheme, let host = base.host else { return nil }
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.port = base.port
        c.path = "/growthbook/"
        return c.url
    }

    /// The link for this app now: an override; else what the paired server advertises
    /// (nil when it publishes no GrowthBook: the line is hidden); else, before the server
    /// has answered once, the derived URL.
    static var current: URL? {
        current(override: ProcessInfo.processInfo.environment["GROWTHBOOK_URL"] ?? UserDefaults.standard.string(forKey: defaultsKey),
                advertised: PairingLink.shared.held, serverBase: LearnerRPC.shared.baseURL)
    }

    static func current(override: String?, advertised: PairingEndpoints?, serverBase: String) -> URL? {
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty { return URL(string: o) }
        if let advertised { return advertised.growthbookApp.flatMap(URL.init(string:)) }
        return url(serverBase: serverBase, override: nil)
    }
}
