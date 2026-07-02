import SwiftUI
import AppKit

// MARK: - Design tokens (ported 1:1 from the macket palette()/density()/buildVars())

enum Appearance: String { case light, dark }
enum Direction: String { case aurora, slate }   // macket "A" / "B"
enum Density: String { case compact, cozy, roomy }

struct Palette {
    let bg, surface, surface2, text, dim, faint, border, edge, node, accent, accentSoft, accentLine: Color
}

extension Palette {
    /// Multiply the alpha of the panel surfaces (sidebar / content / cards) by `m`.
    /// `m >= 1` returns self unchanged (the default preset look).
    func scalingSurface(_ m: Double) -> Palette {
        guard m < 1.0 else { return self }
        return Palette(bg: bg, surface: surface.opacity(m), surface2: surface2.opacity(m),
                       text: text, dim: dim, faint: faint, border: border, edge: edge,
                       node: node, accent: accent, accentSoft: accentSoft, accentLine: accentLine)
    }
}

final class Theme: ObservableObject {
    @Published var appearance: Appearance = .dark { didSet { persist() } }
    @Published var direction: Direction = .aurora { didSet { persist() } }
    @Published var accentHex: String = "#9b8aae" { didSet { persist() } }
    @Published var density: Density = .cozy { didSet { persist() } }
    @Published var bgHex: String?      { didSet { persist() } }
    @Published var surfaceHex: String? { didSet { persist() } }
    @Published var textHex: String?    { didSet { persist() } }
    @Published var homeBgImage: String? { didSet { persist() } }
    @Published var surfaceOpacity: Double = 1.0 { didSet { persist() } }   // 1.0 = preset look; lower = more transparent panels
    @Published var searchEngine: SearchEngine = .google { didSet { persist() } }
    @Published var blockTrackers: Bool = false {
        didSet {
            persist()
            guard ready, blockTrackers != oldValue else { return }
            if blockTrackers { ContentBlocker.shared.prepare { _ in WebViewPool.shared.applyContentRules(true) } }
            else { WebViewPool.shared.applyContentRules(false) }
        }
    }

    static weak var current: Theme?
    private var ready = false

    init() {
        if let s = Store.load(PersistedSettings.self, from: "settings.json") {
            appearance = Appearance(rawValue: s.appearance) ?? .dark
            direction = Direction(rawValue: s.direction) ?? .aurora
            accentHex = s.accentHex
            density = Density(rawValue: s.density) ?? .cozy
            bgHex = s.bgHex
            surfaceHex = s.surfaceHex
            textHex = s.textHex
            homeBgImage = s.homeBgImage
            surfaceOpacity = s.surfaceOpacity ?? 1.0
            searchEngine = s.searchEngine.flatMap(SearchEngine.init(rawValue:)) ?? .google
            blockTrackers = s.blockTrackers ?? false
        }
        ready = true
        persist()   // ensure settings.json exists from first launch
        Theme.current = self
        if blockTrackers { ContentBlocker.shared.prepare() }   // warm the rule list
    }

    private func persist() {
        guard ready else { return }   // don't write while loading defaults
        Store.save(PersistedSettings(appearance: appearance.rawValue,
                                     direction: direction.rawValue,
                                     accentHex: accentHex,
                                     density: density.rawValue,
                                     bgHex: bgHex,
                                     surfaceHex: surfaceHex,
                                     textHex: textHex,
                                     homeBgImage: homeBgImage,
                                     surfaceOpacity: surfaceOpacity,
                                     searchEngine: searchEngine.rawValue,
                                     blockTrackers: blockTrackers),
                   to: "settings.json")
    }

    var accent: Color { Color(hex: accentHex) }
    var isDark: Bool { appearance == .dark }

    /// Final palette: preset/overridden tokens with the user's panel-translucency
    /// multiplier applied to the surface fills.
    var palette: Palette { basePalette.scalingSurface(surfaceOpacity) }

    private var basePalette: Palette {
        let dark = appearance == .dark
        let warm = direction == .aurora
        let acc = Color(hex: accentHex)
        // preset base values (unchanged from the original tables)
        let presetBg:      Color = dark ? Color(hex: warm ? "#15131b" : "#111419")
                                        : Color(hex: warm ? "#f6f3f0" : "#eef1f3")
        let presetSurface: Color = dark ? (warm ? Color(rgba: (36, 32, 46, 0.60)) : Color(rgba: (25, 29, 35, 0.62)))
                                        : (warm ? Color(rgba: (255, 253, 251, 0.62)) : Color(rgba: (255, 255, 255, 0.64)))
        let presetText:    Color = dark ? Color(hex: warm ? "#efeaf5" : "#e7edf3")
                                        : Color(hex: warm ? "#2c2630" : "#1f2630")
        let presetNode:    Color = dark ? Color(hex: warm ? "#2a2536" : "#1f242b") : Color(hex: "#ffffff")
        // apply overrides
        let bg      = bgHex.map      { Color(hex: $0) } ?? presetBg
        let surface = surfaceHex.map { Color(hex: $0) } ?? presetSurface
        let text    = textHex.map    { Color(hex: $0) } ?? presetText
        // any override active => derive secondary tokens from the base colors
        let custom = bgHex != nil || surfaceHex != nil || textHex != nil
        if custom {
            return Palette(
                bg: bg, surface: surface, surface2: surface,
                text: text,
                dim:   text.opacity(0.62),
                faint: text.opacity(0.45),
                border: text.opacity(0.10),
                edge:   text.opacity(0.16),
                node: surfaceHex != nil ? surface : presetNode,
                accent: acc, accentSoft: acc.opacity(0.18), accentLine: acc.opacity(0.5))
        }
        if dark {
            return Palette(
                bg: bg,
                surface:  surface,
                surface2: warm ? Color(rgba: (34, 30, 44, 0.62)) : Color(rgba: (25, 29, 35, 0.62)),
                text:     text,
                dim:      Color(hex: warm ? "#a59cb3" : "#97a1ad"),
                faint:    Color(hex: warm ? "#6d6680" : "#616b77"),
                border:   Color(rgba: (255, 255, 255, 0.08)),
                edge:     Color(rgba: (255, 255, 255, 0.13)),
                node:     presetNode,
                accent:   acc, accentSoft: acc.opacity(0.24), accentLine: acc.opacity(0.5))
        } else {
            return Palette(
                bg: bg,
                surface:  surface,
                surface2: warm ? Color(rgba: (251, 249, 246, 0.66)) : Color(rgba: (255, 255, 255, 0.66)),
                text:     text,
                dim:      Color(hex: warm ? "#7a7282" : "#697480"),
                faint:    Color(hex: warm ? "#aaa2b0" : "#9aa4ae"),
                border:   warm ? Color(rgba: (44, 32, 54, 0.09)) : Color(rgba: (24, 34, 46, 0.09)),
                edge:     warm ? Color(rgba: (44, 32, 54, 0.16)) : Color(rgba: (24, 34, 46, 0.15)),
                node:     presetNode,
                accent:   acc, accentSoft: acc.opacity(0.14), accentLine: acc.opacity(0.5))
        }
    }

    func resetCustomColors() {
        bgHex = nil; surfaceHex = nil; textHex = nil
    }

    var homeBackgroundURL: URL? {
        homeBgImage.map { Store.backgroundsDir.appendingPathComponent($0) }
    }

    /// Copy the chosen image into backgroundsDir under a fresh name, drop the
    /// previous one, and persist just the filename (survives moving the original).
    func setHomeBackground(from url: URL) {
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let name = UUID().uuidString + "." + ext
        let dest = Store.backgroundsDir.appendingPathComponent(name)
        do {
            try Data(contentsOf: url).write(to: dest, options: .atomic)
            if let old = homeBgImage {
                try? FileManager.default.removeItem(at: Store.backgroundsDir.appendingPathComponent(old))
            }
            homeBgImage = name
        } catch {
            NSLog("Somnia: set home background failed — \(error)")
        }
    }

    func clearHomeBackground() {
        if let old = homeBgImage {
            try? FileManager.default.removeItem(at: Store.backgroundsDir.appendingPathComponent(old))
        }
        homeBgImage = nil
    }

    enum ColorKey { case background, surface, text }

    /// Two-way Color binding for a custom override. Reads the current palette
    /// value when the override is nil so the picker opens on the live color.
    func binding(for key: ColorKey) -> Binding<Color> {
        Binding(
            get: {
                switch key {
                case .background: return self.palette.bg
                case .surface:    return self.palette.surface
                case .text:       return self.palette.text
                }
            },
            set: { newColor in
                let hex = newColor.hexString
                switch key {
                case .background: self.bgHex = hex
                case .surface:    self.surfaceHex = hex
                case .text:       self.textHex = hex
                }
            })
    }

    // density()
    var sideW: CGFloat  { density == .compact ? 230  : density == .roomy ? 290  : 262 }
    var tabH: CGFloat   { density == .compact ? 31   : density == .roomy ? 44   : 37 }
    var tabFont: CGFloat { density == .compact ? 12.5 : density == .roomy ? 14.5 : 13.5 }
    var rowGap: CGFloat { density == .compact ? 2    : density == .roomy ? 7    : 4 }

    // direction flags (Slate sits flush: no gap, no radius)
    var appGap: CGFloat      { direction == .aurora ? 10 : 0 }
    var radiusPanel: CGFloat { direction == .aurora ? 16 : 0 }
    var radiusCard: CGFloat  { direction == .aurora ? 20 : 0 }
}

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 6 {
            self.init(.sRGB,
                      red: Double((v >> 16) & 0xff) / 255,
                      green: Double((v >> 8) & 0xff) / 255,
                      blue: Double(v & 0xff) / 255,
                      opacity: 1)
        } else {
            self = .gray
        }
    }
    init(rgba: (Double, Double, Double, Double)) {
        self.init(.sRGB, red: rgba.0 / 255, green: rgba.1 / 255, blue: rgba.2 / 255, opacity: rgba.3)
    }

    /// sRGB hex string like "#aabbcc" (drops alpha). nil if not representable.
    var hexString: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((c.redComponent   * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent  * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

// MARK: - Shared backgrounds

/// Translucent panel surface backed by a within-window blur so it picks up
/// the aurora wash / live page behind it.
struct PanelBackground: View {
    @EnvironmentObject var theme: Theme
    var radius: CGFloat
    var body: some View {
        ZStack {
            VisualEffect(material: .underPageBackground, blending: .withinWindow)
            theme.palette.surface
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct AuroraGlow: View {
    @EnvironmentObject var theme: Theme
    var body: some View {
        ZStack {
            RadialGradient(colors: [theme.accent.opacity(theme.isDark ? 0.18 : 0.14), .clear],
                           center: UnitPoint(x: 0.16, y: -0.05), startRadius: 0, endRadius: 760)
            RadialGradient(colors: [theme.accent.opacity(theme.isDark ? 0.13 : 0.10), .clear],
                           center: UnitPoint(x: 1.05, y: 1.1), startRadius: 0, endRadius: 680)
        }
    }
}
