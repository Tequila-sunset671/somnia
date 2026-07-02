import Foundation

// MARK: - Codable snapshots

struct PersistedTab: Codable {
    let id: UUID
    var title: String
    var url: String?
    var letter: String
    var tintHex: String
}

struct PersistedSpace: Codable {
    let id: UUID
    var name: String
    var accentHex: String
    var tabs: [PersistedTab]
}

struct Bookmark: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var url: String
    var letter: String
    var tintHex: String

    init(id: UUID = UUID(), title: String, url: String, letter: String, tintHex: String) {
        self.id = id
        self.title = title
        self.url = url
        self.letter = letter
        self.tintHex = tintHex
    }
}

struct PersistedSession: Codable {
    var spaces: [PersistedSpace]
    var activeSpaceID: UUID?
    var activeTabID: UUID?
    var maxLiveTabs: Int
    var bookmarks: [Bookmark]?     // optional for backward compatibility
    var sidebarCollapsed: Bool?
}

struct PersistedSettings: Codable {
    var appearance: String
    var direction: String
    var accentHex: String
    var density: String
    var bgHex: String?       // optional theme overrides (nil = use preset)
    var surfaceHex: String?
    var textHex: String?
    var homeBgImage: String?      // filename in Store.backgroundsDir (nil = none)
    var surfaceOpacity: Double?   // panel translucency multiplier (nil = 1.0 = preset look)
    var searchEngine: String?     // SearchEngine rawValue (nil = google)
    var blockTrackers: Bool?      // content blocker on/off (nil = off)
}

// MARK: - JSON store in Application Support/Somnia

enum Store {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Somnia", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Where copied Home background images live (kept with the other app data).
    static let backgroundsDir: URL = {
        let d = dir.appendingPathComponent("backgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Vault (markdown notes) lives with the rest of the app data in
    /// `~/Library/Application Support/Somnia/Vault`. This makes the shipped
    /// `.app` self-contained and portable (a copy handed to another machine,
    /// or run without the source tree next to it, keeps its notes). On first
    /// launch after the move, `migrateLegacyVault()` copies any notes from the
    /// old source-tree location (`SomniaApp/Vault`, pinned via `#filePath`).
    static let vaultDir: URL = {
        let v = dir.appendingPathComponent("Vault", isDirectory: true)
        try? FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
        migrateLegacyVault(into: v)
        return v
    }()

    /// One-time copy of markdown notes from the pre-0.2 source-tree vault into
    /// the new Application Support vault. No-op once the new vault has any `.md`
    /// (so it never re-imports after the user has edited/deleted notes) or when
    /// the legacy folder doesn't exist (fresh installs, shipped copies).
    private static func migrateLegacyVault(into newVault: URL) {
        let fm = FileManager.default
        let alreadyPopulated = (try? fm.contentsOfDirectory(at: newVault, includingPropertiesForKeys: nil))?
            .contains { $0.pathExtension == "md" } ?? false
        if alreadyPopulated { return }

        // Legacy location: .../SomniaApp/Vault, derived from this file's build path.
        let legacy = URL(fileURLWithPath: #filePath)   // .../SomniaApp/Sources/Somnia/Store.swift
            .deletingLastPathComponent()               // .../Sources/Somnia
            .deletingLastPathComponent()               // .../Sources
            .deletingLastPathComponent()               // .../SomniaApp
            .appendingPathComponent("Vault", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path),
              let files = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "md" {
            let dest = newVault.appendingPathComponent(url.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: url, to: dest) }
        }
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let url = dir.appendingPathComponent(name)
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Somnia: save \(name) failed — \(error)")
        }
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
