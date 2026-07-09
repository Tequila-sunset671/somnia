import Foundation
import Network
import WebKit
import Combine

enum ProxyType: String, Codable, CaseIterable { case socks5, http }

struct ProxyConfig: Codable, Equatable {
    var type: ProxyType
    var host: String
    var port: Int
    var username: String?
    var password: String?
}

enum DataStoreKind { case direct, proxied }

func dataStoreKind(proxyEnabled: Bool) -> DataStoreKind {
    proxyEnabled ? .proxied : .direct
}

final class ProxyStore: ObservableObject {
    static let shared = ProxyStore()
    static let proxiedStoreID = UUID(uuidString: "5F0C1B2E-8A44-4E2A-9C3D-7A1B2C3D4E5F")!

    @Published var config: ProxyConfig? { didSet { persist() } }
    private var ready = false

    init() {
        config = Store.load(ProxyConfig.self, from: "proxy.json")
        ready = true
    }

    static func validate(_ c: ProxyConfig) -> Bool {
        !c.host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(c.port)
    }

    var isConfigured: Bool {
        if let c = config { return ProxyStore.validate(c) }
        return false
    }

    func persist() {
        guard ready else { return }
        if let c = config { Store.save(c, to: "proxy.json") }
    }

    func makeProxyConfiguration() -> ProxyConfiguration? {
        guard let c = config, ProxyStore.validate(c) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(c.host),
                                           port: NWEndpoint.Port(rawValue: UInt16(c.port))!)
        let cfg: ProxyConfiguration
        switch c.type {
        case .socks5: cfg = ProxyConfiguration(socksv5Proxy: endpoint)
        case .http:   cfg = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        }
        if let u = c.username, let p = c.password, !u.isEmpty {
            cfg.applyCredential(username: u, password: p)
        }
        return cfg
    }
}
