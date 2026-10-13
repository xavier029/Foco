import AVFoundation
import CoreImage

struct FocoError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

/// Posição do mouse: x, y normalizados 0…1 (origem no topo); c = índice do formato do cursor em Events.cursors
struct Sample: Codable { var t, x, y: Double; var c: Int? = nil }

/// Formato de cursor visto durante a gravação (imagem em cursors/<file>), medidas em pontos
struct CursorShape: Codable { var file: String; var hotX, hotY, width, height: Double; var isArrow: Bool }

/// Tecla pressionada: s = rótulo ("⌘C", "A", "↩"); combo = tem ⌘, ⌃ ou ⌥; x, y = cursor de texto (normalizado), se houver
struct KeyPress: Codable { var t: Double; var s: String; var combo: Bool; var x: Double? = nil; var y: Double? = nil }

/// Anotação ou mosaico: p = [x0, y0, x1, y1] na tela gravada (normalizado, y para baixo); a, b = tempo da gravação
struct Overlay: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case text = "Texto", rect = "Retângulo", oval = "Círculo", arrow = "Seta", line = "Linha", mosaic = "Mosaico"
        case camFull = "Câmera em tela cheia", camNone = "Sem câmera" // layout da câmera no trecho
        var isLayout: Bool { self == .camFull || self == .camNone }
    }
    var id = UUID()
    var kind: Kind
    var a: Double
    var b: Double
    var p: [Double]
    var text = "Texto"
    var color = RGBA(r: 1, g: 0.27, b: 0.23, a: 1)
    var width = 4.0          // espessura da linha (pt) ou força do mosaico
    var opacity = 1.0
    var radius = 0.0         // raio do canto (retângulo, texto e mosaico)
    var bold = true
    var background = RGBA(r: 0, g: 0, b: 0, a: 0.6) // fundo do texto
    var transition: Bool? = nil // layout: "Animação" na entrada e na saída (nil = ligada; opcional para abrir projetos antigos)
    var box: CGRect { CGRect(x: min(p[0], p[2]), y: min(p[1], p[3]), width: abs(p[2] - p[0]), height: abs(p[3] - p[1])) }
}

struct Events: Codable {
    var samples: [Sample]
    var clicks: [Double]
    var pointScale: Double
    var cameraOffset: Double? = nil // início da câmera em relação ao início da tela (s)
    var cursors: [CursorShape]? = nil
    var keys: [KeyPress]? = nil
    var audio: [String]? = nil // faixas de áudio do raw.mov, em ordem: "system", "mic"
    var pauses: [[Double]]? = nil // trechos pausados [início, fim] (s); viram cortes entre clipes
}

/// Trecho com zoom completo entre a e b (tempo da gravação, s)
struct Zoom: Codable, Identifiable, Equatable {
    var id = UUID()
    var a: Double
    var b: Double
    var scale: Double
    var off: Bool? = nil        // "Desativar Zoom"
    var focus: [Double]? = nil  // modo Manual: centro fixo (x, y normalizados, y para baixo); nil = segue o cursor
    var d3: Bool? = nil         // Zoom 3D (FocuSee: type .d3)
    var effect: Int? = nil      // 3D automático: 0 Leve, 1 Padrão, 2 Forte (padrão 1)
    var manual3D: [Double]? = nil // 3D manual: [eixo X, eixo Y, eixo Z, campo de visão] em graus
}

/// Zoom 3D do FocuSee: inclinação a partir do ponto de foco (x, y em 0…1) e da intensidade
enum Zoom3D {
    static func auto(x: Double, y: Double, effect: Int) -> [Double] {
        let x = min(max(x, 0), 1), y = min(max(y, 0), 1)
        switch effect {
        case 0: return [-12 - 6 * y, 20 - 40 * x, 0, 30]
        case 2: return [-35 + 15 * y, 25 - 50 * x, -6 * (2 * x - 1) * y, 35]
        default: return [-30 + 5 * y, 20 - 40 * x, -4 * (2 * x - 1) * y, 30]
        }
    }
    /// Presets do modo manual (eixo X, eixo Y, eixo Z, campo de visão)
    static let presets: [(String, [Double])] = [
        ("Esquerda", [0, 25, 0, 35]), ("Direita", [0, -25, 0, 35]), ("Frente", [0, 0, 0, 30]),
        ("Diagonal esq.", [-20, 20, 0, 40]), ("Diagonal dir.", [-20, -20, 0, 40]), ("Vista de cima", [35, 0, 0, 53]),
        ("Vista de baixo", [-35, 0, 0, 53]), ("Superior esq.", [-40, 40, -2, 35]), ("Superior dir.", [-40, -40, -2, 35]),
    ]
}

/// Estilo do zoom automático (FocuSee: none, D2, D3)
enum AutoZoomStyle: String, Codable, CaseIterable { case none = "Nenhum", d2 = "Zoom 2D", d3 = "Zoom 3D" }

/// Filtros da câmera (FocuSee: CIColorControls → CISharpenLuminance → CITemperatureAndTint)
enum CameraFilter: String, Codable, CaseIterable {
    case none = "Nenhum", natural = "Natural", cold = "Frio", warm = "Aquecido", movie = "Filme", art = "Arte", dark = "Escuro"
    /// saturação, brilho, contraste, nitidez, neutral (temp, tint), targetNeutral (temp, tint)
    var params: (Double, Double, Double, Double, CGPoint, CGPoint)? {
        switch self {
        case .none: nil
        case .natural: (1.2, 0.049, 1.045, 0.5, CGPoint(x: 6500, y: 3.005), CGPoint(x: 6019.97, y: 1.191))
        case .cold: (0.906, 0, 1, 0.504, CGPoint(x: 3903.56, y: 0), CGPoint(x: 6500, y: 0))
        case .warm: (0.906, 0, 1, 0.45, CGPoint(x: 6500, y: 0.458), CGPoint(x: 5034.13, y: -25.35))
        case .movie: (1.408, 0.055, 1.086, 0.509, CGPoint(x: 6500, y: 0), CGPoint(x: 6500, y: 0))
        case .art: (0.607, 0.1537, 1.223, 0.4, CGPoint(x: 5039.78, y: 0), CGPoint(x: 6500, y: 30.824))
        case .dark: (0, 0.02, 1.035, 0.45, CGPoint(x: 6500, y: 0), CGPoint(x: 6500, y: 0))
        }
    }
}

/// Trecho da gravação que entra no vídeo final, na ordem da linha do tempo
struct Clip: Codable, Identifiable, Equatable {
    var id = UUID()
    var a: Double            // início e fim na gravação (s)
    var b: Double
    var speed = 1.0
    var mic = 1.0            // volumes (1 = 100)
    var system = 1.0
    var len: Double { (b - a) / speed } // duração no vídeo final
}

extension Array where Element == Clip {
    var total: Double { reduce(0) { $0 + $1.len } }
    /// início do clipe i no vídeo final
    func start(_ i: Int) -> Double { self[..<i].reduce(0) { $0 + $1.len } }
    /// tempo do vídeo final -> (clipe, tempo da gravação)
    func source(_ t: Double) -> (Int, Double) {
        var o = 0.0
        for (i, c) in enumerated() {
            if t < o + c.len || i == count - 1 { return (i, c.a + Swift.min(Swift.max(t - o, 0), c.len) * c.speed) }
            o += c.len
        }
        return (0, 0)
    }
    /// tempo da gravação -> tempo do vídeo final; num trecho removido, o início do clipe seguinte
    func output(_ s: Double) -> Double {
        var o = 0.0
        for c in self {
            if s < c.a { return o }
            if s <= c.b { return o + (s - c.a) / c.speed }
            o += c.len
        }
        return o
    }
}

struct RGBA: Codable, Equatable {
    var r, g, b, a: Double
    var ci: CIColor { CIColor(red: r, green: g, blue: b, alpha: a) }
}

enum Aspect: String, Codable, CaseIterable, Identifiable {
    case original = "Original", wide = "16:9", square = "1:1", classic = "4:3", vertical = "9:16", portrait = "4:5"
    var id: String { rawValue }
    var ratio: Double? {
        switch self {
        case .original: nil
        case .wide: 16.0 / 9
        case .square: 1
        case .classic: 4.0 / 3
        case .vertical: 9.0 / 16
        case .portrait: 4.0 / 5
        }
    }
    static let presets: [(name: String, icon: String, aspect: Aspect)] = [
        ("YouTube (16:9)", "play.rectangle.fill", .wide),
        ("TikTok / Reels (9:16)", "music.note", .vertical),
        ("Instagram (1:1)", "camera", .square),
        ("Instagram retrato (4:5)", "camera", .portrait),
        ("LinkedIn (1:1)", "person.crop.square", .square),
        ("X / Twitter (16:9)", "bubble.left", .wide),
        ("Facebook (16:9)", "f.square", .wide),
    ]
}

enum BackgroundKind: String, Codable { case gradient, color, wallpaper, image }

enum ClickEffect: String, Codable, CaseIterable, Identifiable {
    case none, regular, collapse, ripple, ring, diffusion, spotlight, sparkle, firework
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Nenhum"
        case .regular: "Padrão"
        case .collapse: "Colapso"
        case .ripple: "Ripple"
        case .ring: "Anel"
        case .diffusion: "Difusão"
        case .spotlight: "Spotlight"
        case .sparkle: "Sparkle"
        case .firework: "Firework"
        }
    }
    var duration: Double { self == .sparkle || self == .firework || self == .spotlight ? 0.7 : 0.5 }
}

/// Molas de movimento da tela (valores do FocuSee: padrão = rigidez 170, amortecimento 50, massa 3)
enum Motion: String, Codable, CaseIterable, Identifiable {
    case slow = "Suave", standard = "Padrão", fast = "Rápido"
    var id: String { rawValue }
    var spring: Spring {
        switch self {
        case .slow: Spring(stiffness: 90, damping: 40, mass: 3)
        case .standard: Spring(stiffness: 170, damping: 50, mass: 3)
        case .fast: Spring(stiffness: 320, damping: 66, mass: 3)
        }
    }
}

struct Spring: Codable, Equatable { var stiffness, damping, mass: Double }

/// Movimento do cursor. Tabela de molas do FocuSee (binário: rigidez 170/470/340, amortecimento 50/70/60, massa 3);
/// o padrão dele (mouseAnimationStyle 2) é 470/70/3. A ordem Lento→Rápido segue a velocidade de cada mola.
enum CursorMotion: String, Codable, CaseIterable, Identifiable {
    case slow = "Lento", mellow = "Médio", quick = "Rápido", custom = "Personalizado"
    var id: String { rawValue }
    var spring: Spring? {
        switch self {
        case .slow: Spring(stiffness: 170, damping: 50, mass: 3)
        case .mellow: Spring(stiffness: 340, damping: 60, mass: 3)
        case .quick: Spring(stiffness: 470, damping: 70, mass: 3)
        case .custom: nil
        }
    }
}

struct Settings: Codable, Equatable {
    // Fundo (padrões do FocuSee: padding 0,05 · round 0,04 · sombra 0,8 · borda interna #59FFFFFF)
    var bgKind = BackgroundKind.gradient
    var gradient = 0
    var color = RGBA(r: 0.11, g: 0.11, b: 0.13, a: 1)
    var imagePath: String? = nil
    var blur = 0.0
    var aspect = Aspect.original
    var padding = 0.05
    var round = 0.04
    var shadow = 0.8
    var inset = 0.0
    var insetColor = RGBA(r: 1, g: 1, b: 1, a: 0.35)
    // Zoom e movimento
    var zoomLevel = 2.0             // FocuSee: Edit.Setting.Zoom.Default 2,0
    var typingZoom = true           // "Zoom automático ao digitar" (segue o cursor de texto)
    var zooms: [Zoom] = []
    var motion = Motion.standard
    var autoZoomStyle = AutoZoomStyle.d2
    var effect3D = 1                // intensidade do 3D automático (Padrão)
    // Desfoque de movimento (FocuSee: ligado; tela 0,5 · zoom 0,5 · cursor 0,5)
    var motionBlur = true
    var screenMoveBlur = 0.5
    var screenZoomBlur = 0.5
    // Cursor (FocuSee: tamanho 3X, caminho suavizado, efeito "regular")
    var showCursor = true
    var cursorSize = 3.0
    var cursorStyle = 0
    var cursorAngle = 0.0
    var smoothCursor = true
    var hideIdle = false
    var idleDuration = 3.0          // FocuSee: idleHideDuration 3
    var cursorDirection = 0.0       // "Direção dinâmica": inclinação máxima (graus) conforme o movimento
    var cursorBlur = 0.5            // "Desfoque de Movimento do Cursor" (FocuSee: cursorMoveBlur 0,5)
    var cursorMotion = CursorMotion.quick
    var cursorSpring = Spring(stiffness: 470, damping: 70, mass: 3) // usado em Personalizado
    var endReturn = false           // "Posição do cursor no final do vídeo": voltar ao início
    var endDuration = 2.0           // FocuSee: videoEndBackToStartDuration 2
    var click = ClickEffect.regular
    var clickColor = RGBA(r: 0.867, g: 0.867, b: 0.867, a: 1) // FocuSee: #FFDDDDDD
    var clickRainbow = false
    var clickOpacity = 0.8          // FocuSee: alpha 0,8
    var clickSize = 50.0            // FocuSee: size 50
    var clickSound = false
    var clickSoundID = 0
    var clickVolume = 1.0
    // Teclas de atalho (FocuSee: só combinações por padrão; "Exibir Tecla de Atalho Única" mostra as demais)
    var showKeys = true
    var keysSingle = false
    var keysTop = false
    var keysSize = 1.0
    var keysColor = RGBA(r: 1, g: 1, b: 1, a: 1)
    var keysBackground = RGBA(r: 0, g: 0, b: 0, a: 0.7)
    // Anotações e mosaicos
    var overlays: [Overlay] = []
    // Câmera (FocuSee: tamanho 0,35 · redonda · encolhe no zoom)
    var showCamera = true
    var cameraSize = 0.35
    var cameraRound = 0.5
    var cameraCorner = 0 // 0 inf. dir., 1 inf. esq., 2 sup. dir., 3 sup. esq.
    var cameraMirror = true
    var cameraShrinkOnZoom = true
    var cameraFilter = CameraFilter.none
    var cameraBorder: [RGBA]? = nil  // moldura: uma cor ou degradê; nil = sem moldura
    var cameraCrop: [Double]? = nil  // recorte da câmera [x, y, largura, altura] normalizados, y para baixo
    // Clipes (vazio = gravação inteira) e recorte da tela [x, y, largura, altura] normalizados, y para baixo
    var clips: [Clip] = []
    var crop: [Double]? = nil
    // Corte de versões antigas (só para converter em clipes)
    var trimStart = 0.0
    var trimEnd: Double? = nil

    func timelineClips(duration: Double) -> [Clip] {
        clips.isEmpty ? [Clip(a: trimStart, b: Swift.min(trimEnd ?? duration, duration))] : clips
    }
    var cropRect: CGRect {
        guard let c = crop, c.count == 4 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: c[0], y: c[1], width: c[2], height: c[3])
    }

    static let gradients: [(RGBA, RGBA)] = [
        (RGBA(r: 0.80, g: 0.55, b: 0.98, a: 1), RGBA(r: 0.45, g: 0.40, b: 0.95, a: 1)),
        (RGBA(r: 0.55, g: 0.80, b: 1.00, a: 1), RGBA(r: 0.25, g: 0.55, b: 0.98, a: 1)),
        (RGBA(r: 0.45, g: 0.93, b: 0.75, a: 1), RGBA(r: 0.20, g: 0.70, b: 0.90, a: 1)),
        (RGBA(r: 0.45, g: 0.92, b: 0.55, a: 1), RGBA(r: 0.20, g: 0.72, b: 0.45, a: 1)),
        (RGBA(r: 1.00, g: 0.72, b: 0.35, a: 1), RGBA(r: 1.00, g: 0.48, b: 0.25, a: 1)),
        (RGBA(r: 1.00, g: 0.62, b: 0.55, a: 1), RGBA(r: 0.93, g: 0.38, b: 0.40, a: 1)),
        (RGBA(r: 1.00, g: 0.55, b: 0.80, a: 1), RGBA(r: 0.90, g: 0.30, b: 0.62, a: 1)),
        (RGBA(r: 0.42, g: 0.55, b: 1.00, a: 1), RGBA(r: 0.35, g: 0.45, b: 0.98, a: 1)),
        (RGBA(r: 0.92, g: 0.80, b: 0.95, a: 1), RGBA(r: 0.85, g: 0.70, b: 0.92, a: 1)),
        (RGBA(r: 0.75, g: 0.95, b: 0.95, a: 1), RGBA(r: 0.65, g: 0.90, b: 0.92, a: 1)),
        (RGBA(r: 0.60, g: 0.80, b: 0.30, a: 1), RGBA(r: 0.50, g: 0.72, b: 0.28, a: 1)),
        (RGBA(r: 1.00, g: 0.90, b: 0.40, a: 1), RGBA(r: 1.00, g: 0.82, b: 0.30, a: 1)),
        (RGBA(r: 1.00, g: 0.60, b: 0.05, a: 1), RGBA(r: 1.00, g: 0.52, b: 0.00, a: 1)),
        (RGBA(r: 0.36, g: 0.27, b: 0.95, a: 1), RGBA(r: 0.93, g: 0.35, b: 0.62, a: 1)),
        (RGBA(r: 0.10, g: 0.12, b: 0.25, a: 1), RGBA(r: 0.30, g: 0.15, b: 0.45, a: 1)),
        (RGBA(r: 0.06, g: 0.07, b: 0.09, a: 1), RGBA(r: 0.20, g: 0.22, b: 0.28, a: 1)),
    ]

    /// sons de clique (sons do macOS)
    static let clickSounds = [("Leve", "Tink"), ("Nítido", "Pop"), ("Forte", "Bottle")]
    /// cores do efeito de clique (a última opção é o arco-íris)
    static let clickColors: [RGBA] = [
        RGBA(r: 0.867, g: 0.867, b: 0.867, a: 1), RGBA(r: 1, g: 0.96, b: 0.38, a: 1), RGBA(r: 1, g: 0.55, b: 0.18, a: 1),
        RGBA(r: 0.55, g: 0.76, b: 0.29, a: 1), RGBA(r: 0.2, g: 0.42, b: 1, a: 1), RGBA(r: 1, g: 0.17, b: 0.33, a: 1),
    ]

    static let colors: [RGBA] = [
        RGBA(r: 1, g: 1, b: 1, a: 1), RGBA(r: 0.93, g: 0.93, b: 0.95, a: 1), RGBA(r: 0.11, g: 0.11, b: 0.13, a: 1), RGBA(r: 0, g: 0, b: 0, a: 1),
        RGBA(r: 0.25, g: 0.45, b: 0.98, a: 1), RGBA(r: 0.55, g: 0.35, b: 0.95, a: 1), RGBA(r: 0.95, g: 0.35, b: 0.60, a: 1), RGBA(r: 0.95, g: 0.30, b: 0.30, a: 1),
        RGBA(r: 1.00, g: 0.55, b: 0.10, a: 1), RGBA(r: 1.00, g: 0.82, b: 0.25, a: 1), RGBA(r: 0.25, g: 0.75, b: 0.45, a: 1), RGBA(r: 0.20, g: 0.70, b: 0.80, a: 1),
    ]

    /// Zoom automático: cada clique (ou sequência de cliques próximos) vira um zoom
    /// Zoom automático do FocuSee (estilo "D2"): cada clique dá [t − 0,32 s, t + 1,266 s], cada trecho de digitação
    /// [início − 0,5 s, fim]; nada passa de 1 s antes do fim; trechos a menos de 2,6 s um do outro viram um só zoom.
    static func autoZooms(_ ev: Events, level: Double, typing: Bool, style: AutoZoomStyle = .d2, effect: Int = 1) -> [Zoom] {
        guard style != .none else { return [] }
        let end = (ev.samples.last?.t ?? 0) - 1
        var ranges: [(Double, Double)] = []
        if typing { ranges += typingRanges(ev.keys ?? []).map { ($0.0 - 0.5, $0.1) } }
        // só cliques dentro da área gravada
        let inside = ev.clicks.filter { c in
            guard let s = ev.samples.last(where: { $0.t <= c }) ?? ev.samples.first else { return true }
            return (0...1).contains(s.x) && (0...1).contains(s.y)
        }
        ranges += inside.map { ($0 - 0.32, $0 + 1.266) }
        var merged: [(Double, Double)] = []
        for r in ranges.map({ (max(0, $0.0), min($0.1, end)) }).filter({ $0.0 <= $0.1 }).sorted(by: { $0.0 < $1.0 }) {
            if let l = merged.last, r.0 <= l.1 + 2.6 { merged[merged.count - 1].1 = max(l.1, r.1) } else { merged.append(r) }
        }
        return merged.filter { $0.1 - $0.0 > 0.2 }.map { Zoom(a: $0.0, b: $0.1, scale: level, d3: style == .d3 ? true : nil, effect: style == .d3 ? effect : nil) }
    }

    /// Trechos de digitação (FocuSee): teclas com no máximo 1,5 s entre si; descarta os que têm menos de 1,5 s e menos de 5 teclas
    static func typingRanges(_ keys: [KeyPress]) -> [(Double, Double)] {
        var out: [(Double, Double)] = [], start = 0.0, last = -10.0, n = 0
        func close() { if n > 0, last - start >= 1.5 || n >= 5 { out.append((start, last)) } }
        for k in keys.sorted(by: { $0.t < $1.t }) {
            if k.t - last > 1.5 { close(); start = k.t; n = 0 }
            last = k.t; n += 1
        }
        close()
        return out
    }

    static func initial(for p: Project, events: Events) -> Settings {
        var s = Settings()
        s.zooms = autoZooms(events, level: s.zoomLevel, typing: s.typingZoom, style: s.autoZoomStyle, effect: s.effect3D)
        s.showCamera = p.camera != nil
        if let ps = events.pauses, !ps.isEmpty, let end = events.samples.last?.t {
            var a = 0.0
            for p in ps {
                if p[0] > a { s.clips.append(Clip(a: a, b: p[0])) }
                a = p[1]
            }
            if end > a { s.clips.append(Clip(a: a, b: end)) }
        }
        return s
    }
}

struct ExportOptions: Codable, Equatable {
    enum Format: String, Codable, CaseIterable { case mp4 = "MP4", gif = "GIF" }
    enum Quality: String, Codable, CaseIterable {
        case high = "Maior", recommended = "Recomendado", low = "Menor"
        var bitsPerPixel: Double { self == .high ? 0.18 : self == .recommended ? 0.10 : 0.05 }
    }
    static let resolutions: [(String, Double?)] = [("Original", nil), ("4K", 2160), ("2K", 1440), ("1080P", 1080), ("720P", 720), ("480P", 480)]
    static let frameRates = [60, 50, 30, 25, 24, 20, 10]

    var format = Format.mp4
    var shortSide: Double? = nil
    var fps = 30
    var quality = Quality.recommended
    var folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Foco").path

    static var saved: ExportOptions {
        guard let d = UserDefaults.standard.data(forKey: "exportOptions"), let o = try? JSONDecoder().decode(ExportOptions.self, from: d) else { return ExportOptions() }
        return o
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "exportOptions") }
}

/// Dados do projeto que não são edição: última abertura e vídeos exportados
struct Meta: Codable {
    var lastOpened: Date? = nil
    var exports: [String] = []
    var title: String? = nil // nome dado em "Renomear" (a pasta continua a mesma)
}

struct Project {
    static let baseDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Foco")
    let dir: URL

    var raw: URL { dir.appending(path: "raw.mov") }
    var camera: URL? {
        let u = dir.appending(path: "camera.mov")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    var name: String { meta.title ?? dir.lastPathComponent }
    var created: Date { (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }

    func loadEvents() throws -> Events {
        try JSONDecoder().decode(Events.self, from: Data(contentsOf: dir.appending(path: "events.json")))
    }

    /// Junta o que foi salvo com os padrões atuais, para projetos antigos continuarem abrindo
    func loadSettings() -> Settings? {
        guard let data = try? Data(contentsOf: dir.appending(path: "project.json")),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: base.merging(stored) { $1 })
        else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: merged)
    }
    func save(_ s: Settings) {
        try? JSONEncoder().encode(s).write(to: dir.appending(path: "project.json"))
    }

    var meta: Meta {
        get { (try? JSONDecoder().decode(Meta.self, from: Data(contentsOf: dir.appending(path: "meta.json")))) ?? Meta() }
        nonmutating set { try? JSONEncoder().encode(newValue).write(to: dir.appending(path: "meta.json")) }
    }

    static func all() -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { fm.fileExists(atPath: $0.appending(path: "raw.mov").path) }
            .sorted { Project(dir: $0).created > Project(dir: $1).created }
    }

    func thumbnails(count: Int, size: CGFloat = 240) async -> [CGImage] {
        let asset = AVURLAsset(url: raw)
        guard let d = try? await asset.load(.duration).seconds, d > 0 else { return [] }
        let g = AVAssetImageGenerator(asset: asset)
        g.maximumSize = CGSize(width: size, height: size)
        var out: [CGImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: d * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let r = try? await g.image(at: t) { out.append(r.image) }
        }
        return out
    }

    /// Amplitude do áudio em `buckets` faixas (0…1), para desenhar a onda na linha do tempo
    func waveform(buckets: Int) async -> [Float] {
        let asset = AVURLAsset(url: raw)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let dur = try? await asset.load(.duration).seconds, dur > 0,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 8000,
        ])
        reader.add(out)
        reader.startReading()
        var peaks = [Float](repeating: 0, count: buckets)
        let perBucket = max(1, Int(dur * 8000) / buckets)
        var i = 0
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            var len = 0
            var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            guard let ptr else { continue }
            ptr.withMemoryRebound(to: Int16.self, capacity: len / 2) { s in
                for k in 0..<(len / 2) {
                    let b = min(i / perBucket, buckets - 1)
                    peaks[b] = max(peaks[b], abs(Float(s[k])) / 32768)
                    i += 1
                }
            }
        }
        let m = max(peaks.max() ?? 1, 0.01)
        return peaks.map { $0 / m }
    }
}

func clock(_ t: Double) -> String {
    let s = max(0, Int(t))
    return String(format: "%d:%02d", s / 60, s % 60)
}
