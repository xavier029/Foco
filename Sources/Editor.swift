import SwiftUI
import AVKit
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    let project: Project
    @Published var settings = Settings() {
        didSet {
            guard settings != oldValue, loaded else { return }
            project.save(settings)
            if !restoring {
                // uma entrada no histórico por gesto (arrastes rápidos viram uma só)
                if Date().timeIntervalSince(lastEdit) > 0.6 { undoStack.append(oldValue); redoStack.removeAll() }
                lastEdit = Date()
            }
            if settings.cursorStyle != oldValue.cursorStyle { style = CursorStyles.art(settings.cursorStyle) }
            applyComposition()
        }
    }
    @Published var time = 0.0       // tempo do vídeo final (= tempo do player)
    @Published var playing = false
    @Published var duration = 1.0   // duração da gravação
    @Published var wave: [Float] = []
    @Published var selected: UUID?      // zoom selecionado
    @Published var selectedClip: UUID?  // clipe selecionado
    @Published var selectedOverlay: UUID? // anotação ou mosaico selecionado
    @Published var selectedTyping: Int?   // trecho de digitação selecionado (índice em typing)
    /// Trechos de digitação da gravação (tempo da gravação)
    var typing: [(Double, Double)] { Settings.typingRanges(events.keys ?? []) }
    @Published var showCrop = false
    @Published var tlZoom = 1.0     // zoom da linha do tempo (1 = tudo visível)
    @Published var exportProgress: Double?
    @Published var error: String?
    @Published private(set) var undoStack: [Settings] = []
    @Published private(set) var redoStack: [Settings] = []
    private(set) var srcSize = CGSize(width: 1920, height: 1080)

    let player = AVPlayer()
    /// quadros prontos da prévia (desenhados pelo FrameView, não pelo player do macOS)
    private(set) var videoOutput: AVPlayerItemVideoOutput?
    private(set) var events = Events(samples: [], clicks: [], pointScale: 2)
    private var timeline: Timeline?
    private(set) var renderer: FrameRenderer? // o da prévia (para posicionar as alças das anotações)
    private var builtFor: [[Double]] = []
    private var loaded = false
    private var restoring = false
    private var lastEdit = Date.distantPast
    private var observer: Any?
    private var rebuilding: Task<Void, Never>?
    private lazy var style = CursorStyles.art(0)
    private var shapes: [CursorArt?] = []

    var clips: [Clip] { settings.clips }
    var total: Double { max(clips.total, 0.1) } // duração do vídeo final
    var inputs: RenderInputs { RenderInputs(project: project, events: events, settings: settings, style: style, shapes: shapes) }
    /// tempo da gravação na agulha
    var sourceTime: Double { clips.isEmpty ? time : clips.source(time).1 }

    let title: String

    init(dir: URL) {
        project = Project(dir: dir)
        title = project.name
        Task { await load() }
    }

    private func load() async {
        do {
            events = try project.loadEvents()
            shapes = CursorStyles.recorded(events, dir: project.dir)
            var st = project.loadSettings() ?? Settings.initial(for: project, events: events)
            let tl = try await makeTimeline(project, events: events, settings: st)
            timeline = tl
            duration = tl.srcDuration
            srcSize = tl.srcSize
            st.clips = tl.clips; st.trimStart = 0; st.trimEnd = nil // versões antigas: o corte vira um clipe
            builtFor = timelineKey(st)
            st.zooms = st.zooms.compactMap { z in var z = z; z.b = min(z.b, tl.srcDuration); return z.b - z.a > 0.2 ? z : nil }
            style = CursorStyles.art(st.cursorStyle)
            settings = st
            loaded = true
            project.save(settings)
            var m = project.meta; m.lastOpened = Date(); project.meta = m
            player.replaceCurrentItem(with: playerItem(tl))
            applyComposition()
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
                MainActor.assumeIsolated { self?.tick(t.seconds) }
            }
            wave = await project.waveform(buckets: 400)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func playerItem(_ tl: Timeline) -> AVPlayerItem {
        let item = AVPlayerItem(asset: tl.asset)
        item.audioTimePitchAlgorithm = .spectral // velocidade sem mudar o tom da voz
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        videoOutput = out
        return item
    }

    private func applyComposition() {
        guard let tl = timeline, let item = player.currentItem else { return }
        if timelineKey(settings) != builtFor { rebuildTimeline(); return }
        guard tl.key == builtFor else { return } // a composição nova ainda está sendo montada
        let r = FrameRenderer(settings: settings, events: events, style: style, shapes: shapes, src: tl.srcSize, shortSide: 720, duration: tl.srcDuration)
        renderer = r
        item.videoComposition = videoComposition(tl, renderer: r, fps: 30, preview: true)
        item.audioMix = tl.audioMix(settings)
        if !playing { seek(time) }
    }

    /// Cortes, trechos e velocidade mudam a composição: monta outra e troca o item do player
    private func rebuildTimeline() {
        rebuilding?.cancel()
        let st = settings
        builtFor = timelineKey(st)
        rebuilding = Task {
            guard let tl = try? await makeTimeline(project, events: events, settings: st), !Task.isCancelled else { return }
            if playing { player.pause(); playing = false }
            timeline = tl
            player.replaceCurrentItem(with: playerItem(tl))
            applyComposition()
        }
    }

    private func tick(_ t: Double) {
        guard playing else { return }
        time = t
        if t >= total - 0.02 { player.pause(); playing = false }
    }

    func togglePlay() {
        if playing {
            player.pause()
        } else {
            if time >= total - 0.05 { seek(0) }
            player.play()
        }
        playing.toggle()
    }

    func seek(_ t: Double) {
        time = min(max(t, 0), total)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(settings)
        restoring = true; settings = prev; restoring = false
        fixSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(settings)
        restoring = true; settings = next; restoring = false
        fixSelection()
    }

    private func fixSelection() {
        if !settings.zooms.contains(where: { $0.id == selected }) { selected = nil }
        if !clips.contains(where: { $0.id == selectedClip }) { selectedClip = nil }
        if !settings.overlays.contains(where: { $0.id == selectedOverlay }) { selectedOverlay = nil }
        if time > total { seek(total) }
    }

    func addZoom(at t: Double? = nil) {
        let o = t ?? time
        let a = clips.source(o).1, b = clips.source(min(o + 2, total)).1
        guard b - a > 0.2 else { return }
        let z = Zoom(a: a, b: b, scale: settings.zoomLevel)
        settings.zooms.append(z)
        selected = z.id
    }

    /// Nova anotação ou mosaico de 3 s na agulha, no meio da tela
    func addOverlay(_ kind: Overlay.Kind) {
        let a = sourceTime, b = clips.source(min(time + 3, total)).1
        guard b - a > 0.2 else { return }
        var o = Overlay(kind: kind, a: a, b: b, p: [0.35, 0.4, 0.65, 0.6])
        switch kind {
        case .arrow: o.p = [0.35, 0.65, 0.55, 0.45]
        case .line: o.p = [0.35, 0.5, 0.65, 0.5]
        case .text: o.p = [0.3, 0.44, 0.7, 0.56]; o.color = RGBA(r: 1, g: 1, b: 1, a: 1); o.radius = 0.4
        case .mosaic: o.width = 8; o.radius = 0.1
        case .rect: o.radius = 0.1
        case .oval, .camFull, .camNone: break
        }
        settings.overlays.append(o)
        selectedOverlay = o.id
    }

    /// "Acelerar" um trecho de digitação: vira um clipe próprio com a velocidade escolhida (1 = volta ao normal)
    func accelerate(_ r: (Double, Double), speed: Double) {
        var st = settings // muda numa cópia: um único passo no desfazer
        func cut(_ s: Double) {
            guard let i = st.clips.firstIndex(where: { s > $0.a + 0.05 && s < $0.b - 0.05 }) else { return }
            var n = st.clips[i]; n.id = UUID(); n.a = s
            st.clips[i].b = s
            st.clips.insert(n, at: i + 1)
        }
        cut(r.0); cut(r.1)
        for i in st.clips.indices where st.clips[i].a >= r.0 - 0.06 && st.clips[i].b <= r.1 + 0.06 { st.clips[i].speed = speed }
        settings = st
        if time > total { seek(total) }
    }

    /// Velocidade atual do trecho (a do clipe que o contém)
    func speed(of r: (Double, Double)) -> Double {
        clips.first { $0.a <= (r.0 + r.1) / 2 && $0.b >= (r.0 + r.1) / 2 }?.speed ?? 1
    }

    /// Tesoura: divide o clipe na agulha
    func split() {
        let (i, s) = clips.source(time)
        let c = clips[i]
        guard s - c.a > 0.1, c.b - s > 0.1 else { return }
        var n = c; n.id = UUID(); n.a = s
        settings.clips[i].b = s
        settings.clips.insert(n, at: i + 1)
        selectedClip = n.id; selected = nil
    }

    /// Lixeira: apaga o zoom ou o clipe selecionado
    func deleteSelected() {
        if let id = selectedOverlay {
            settings.overlays.removeAll { $0.id == id }
            selectedOverlay = nil
        } else if selected != nil {
            settings.zooms.removeAll { $0.id == selected }
            selected = nil
        } else if let id = selectedClip, clips.count > 1 {
            settings.clips.removeAll { $0.id == id }
            selectedClip = nil
            if time > total { seek(total) }
        }
    }

    var canDelete: Bool { selected != nil || selectedOverlay != nil || (selectedClip != nil && clips.count > 1) }

    func regenerateZooms() {
        settings.zooms = Settings.autoZooms(events, level: settings.zoomLevel, typing: settings.typingZoom,
                                            style: settings.autoZoomStyle, effect: settings.effect3D)
        selected = nil
    }

    func export(_ o: ExportOptions, name: String) {
        exportProgress = 0
        let inp = inputs, p = project
        Task {
            do {
                let url = try await exportVideo(inp, options: o, name: name) { v in Task { @MainActor in self.exportProgress = v } }
                var m = p.meta; m.exports.insert(url.path, at: 0); p.meta = m
                exportProgress = nil
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                exportProgress = nil
                self.error = error.localizedDescription
            }
        }
    }
}

enum InspectorTab: String, CaseIterable {
    case background = "Fundo", cursor = "Cursor", zoom = "Zoom", camera = "Câmera", annotation = "Anotação", mosaic = "Mosaico", keys = "Teclas de atalho"
    var icon: String {
        switch self {
        case .background: "square.on.square.dashed"
        case .cursor: "cursorarrow"
        case .zoom: "plus.magnifyingglass"
        case .camera: "web.camera"
        case .annotation: "pencil.and.outline"
        case .mosaic: "checkerboard.rectangle"
        case .keys: "command"
        }
    }
}

struct EditorView: View {
    @StateObject private var m: EditorModel
    @State private var tab = InspectorTab.background
    @State private var showExport = false
    @Environment(\.openWindow) private var openWindow

    init(dir: URL) { _m = StateObject(wrappedValue: EditorModel(dir: dir)) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Inspector(m: m, tab: tab)
                .frame(width: 340)
                .background(Theme.panel)
            Rectangle().fill(Theme.stroke).frame(width: 1)
            VStack(spacing: 0) {
                topBar
                PlayerView(m: m)
                    .overlay(Color.clear.contentShape(Rectangle()).onTapGesture {
                        if !m.clips.isEmpty { m.selectedClip = m.clips[m.clips.source(m.time).0].id }
                    })
                    .overlay(OverlayEditor(m: m))
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                transport
                TimelineStrip(m: m).frame(height: 228)
            }
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(edges: .top)
        .sheet(isPresented: $showExport) { ExportSheet(m: m) }
        .sheet(isPresented: $m.showCrop) { CropSheet(m: m) }
        .onChange(of: m.selected) { _, s in if s != nil { tab = .zoom; m.selectedClip = nil; m.selectedOverlay = nil } }
        .onChange(of: m.selectedClip) { _, s in if s != nil { m.selected = nil; m.selectedOverlay = nil; m.selectedTyping = nil } }
        .onChange(of: m.selectedTyping) { _, s in if s != nil { m.selected = nil; m.selectedOverlay = nil; m.selectedClip = nil } }
        .onChange(of: m.selectedOverlay) { _, s in
            guard let o = m.settings.overlays.first(where: { $0.id == s }) else { return }
            tab = o.kind.isLayout ? .camera : o.kind == .mosaic ? .mosaic : .annotation; m.selected = nil; m.selectedClip = nil
        }
        .alert("Erro", isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) {
            Button("OK") {}
        } message: { Text(m.error ?? "") }
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            ForEach(InspectorTab.allCases, id: \.self) { t in
                Button { tab = t; m.selected = nil; m.selectedClip = nil; m.selectedOverlay = nil; m.selectedTyping = nil } label: {
                    Image(systemName: t.icon).font(.system(size: 20))
                        .frame(width: 50, height: 50)
                        .foregroundStyle(tab == t && m.selectedClip == nil ? .white : Theme.text2)
                        .background(tab == t && m.selectedClip == nil ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .help(t.rawValue)
            }
            Spacer()
        }
        .padding(.top, 52).padding(.horizontal, 10)
        .frame(width: 70)
        .background(Theme.bg)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Text(m.title).font(.headline).lineLimit(1)
            Spacer()
            Button { openWindow(id: "history"); NSApp.activate() } label: {
                Image(systemName: "clock").font(.system(size: 16, weight: .medium)).frame(width: 38, height: 34)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Histórico do Arquivo")
            Button { showExport = true } label: { Label("Exportar", systemImage: "square.and.arrow.up") }
                .buttonStyle(GradientButtonStyle()).frame(width: 140)
                .keyboardShortcut("e", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20).frame(height: 52)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    /// Barra da linha do tempo (como a do FocuSee): cortar, dividir, desfazer, refazer, apagar · reproduzir
    private var transport: some View {
        HStack(spacing: 4) {
            tool("crop", "Cortar vídeo") { m.showCrop = true }
            tool("scissors", "Dividir o clipe na agulha (⌘B)") { m.split() }
                .keyboardShortcut("b", modifiers: .command)
            tool("arrow.uturn.backward", "Desfazer (⌘Z)") { m.undo() }
                .keyboardShortcut("z", modifiers: .command).disabled(m.undoStack.isEmpty)
            tool("arrow.uturn.forward", "Refazer (⇧⌘Z)") { m.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(m.redoStack.isEmpty)
            tool("trash", "Apagar o item selecionado (⌫)") { m.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: []).disabled(!m.canDelete)
            Spacer()
            // zoom da linha do tempo (FocuSee: "Ampliar/Reduzir zoom da linha do tempo" e "Ajuste da linha do tempo")
            tool("arrow.left.and.right.square", "Ajustar a linha do tempo à tela (⌘0)") { m.tlZoom = 1 }
                .keyboardShortcut("0", modifiers: .command)
            tool("minus", "Reduzir zoom da linha do tempo (⌘−)") { m.tlZoom = max(1, m.tlZoom / 1.5) }
                .keyboardShortcut("-", modifiers: .command).disabled(m.tlZoom <= 1)
            Slider(value: Binding(get: { log(m.tlZoom) }, set: { m.tlZoom = exp($0) }), in: 0...log(20))
                .frame(width: 110).tint(Theme.accent)
            tool("plus", "Ampliar zoom da linha do tempo (⌘+)") { m.tlZoom = min(20, m.tlZoom * 1.5) }
                .keyboardShortcut("=", modifiers: .command).disabled(m.tlZoom >= 20)
            Rectangle().fill(Theme.stroke).frame(width: 1, height: 22).padding(.horizontal, 8)
            Button { m.togglePlay() } label: {
                Image(systemName: m.playing ? "pause.circle" : "play.circle").font(.system(size: 22)).frame(width: 30)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            Text("\(clock(m.time)) / \(clock(m.total))").monospacedDigit().foregroundStyle(Theme.text2)
        }
        .background {
            // Ctrl+Z também desfaz (costume do Windows)
            Group {
                Button("") { m.undo() }.keyboardShortcut("z", modifiers: .control)
                Button("") { m.redo() }.keyboardShortcut("z", modifiers: [.control, .shift])
            }
            .opacity(0).allowsHitTesting(false)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func tool(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium)).frame(width: 38, height: 32)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// Prévia do vídeo. O player do macOS mostra quadros RGB com a curva do Rec.709 qualquer que seja a marcação,
/// o que clareia os escuros (medido: 23,32,48 aparecia como 36,45,57). Aqui cada quadro pronto vira uma imagem sRGB
/// num CALayer, que respeita o gerenciamento de cor, e a prévia fica igual à tela.
struct PlayerView: NSViewRepresentable {
    let m: EditorModel
    func makeNSView(context: Context) -> FrameView { FrameView(m: m) }
    func updateNSView(_ v: FrameView, context: Context) {}
}

final class FrameView: NSView {
    private weak var m: EditorModel?
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var link: CADisplayLink?

    init(m: EditorModel) {
        self.m = m
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @MainActor @objc private func tick() {
        guard let m, let out = m.videoOutput else { return }
        let t = out.itemTime(forHostTime: CACurrentMediaTime())
        guard out.hasNewPixelBuffer(forItemTime: t), let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        let img = CIImage(cvPixelBuffer: pb, options: [.colorSpace: VideoColor.screen])
        layer?.contents = ci.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: VideoColor.screen)
    }
}

// MARK: - Painel lateral

struct Inspector: View {
    @ObservedObject var m: EditorModel
    let tab: InspectorTab
    @State private var bgTab = 0
    @State private var accelRate = 3.0
    @State private var showCameraCrop = false
    @State private var wallpapers: [(path: String, thumb: CGImage)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let i = m.clips.firstIndex(where: { $0.id == m.selectedClip }) { clipConfig(i) }
                else if let k = m.selectedTyping, k < m.typing.count { typingConfig(k) }
                else { content }
            }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 34)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .background: background
        case .cursor: cursor
        case .zoom: zoom
        case .camera: camera
        case .annotation: annotation
        case .mosaic: mosaic
        case .keys: keys
        }
    }

    // MARK: Anotação (Texto e Formas do FocuSee)

    private var overlayIndex: Int? { m.settings.overlays.firstIndex { $0.id == m.selectedOverlay } }

    @ViewBuilder private var annotation: some View {
        if let i = overlayIndex, m.settings.overlays[i].kind != .mosaic {
            overlayConfig(i)
        } else {
            SectionTitle("Anotação")
            Text("Escolha um tipo para colocar na agulha. Arraste na prévia para posicionar e na linha do tempo para mudar a duração.")
                .font(.callout).foregroundStyle(Theme.text2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(Overlay.Kind.allCases.filter { $0 != .mosaic && !$0.isLayout }, id: \.self) { k in
                    VStack(spacing: 6) {
                        Tile(selected: false, action: { m.addOverlay(k) }) { Image(systemName: Self.icon(k)).font(.system(size: 22)) }
                            .frame(height: 58)
                        Text(k.rawValue).font(.callout).foregroundStyle(Theme.text2)
                    }
                }
            }
        }
    }

    static func icon(_ k: Overlay.Kind) -> String {
        switch k {
        case .text: "textformat"
        case .rect: "rectangle"
        case .oval: "circle"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .mosaic: "checkerboard.rectangle"
        case .camFull: "person.crop.rectangle.fill"
        case .camNone: "video.slash"
        }
    }

    @ViewBuilder private func overlayConfig(_ i: Int) -> some View {
        let o = $m.settings.overlays[i]
        let k = o.wrappedValue.kind
        SectionTitle(k == .text ? "Configurações de texto" : "Configurações de forma")
        if k == .text {
            TextField("Inserir texto", text: o.text, axis: .vertical)
                .textFieldStyle(.plain).padding(10)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 9))
            Toggle("Negrito", isOn: o.bold).toggleStyle(.switch).tint(Theme.accent)
        }
        HStack {
            Text(k == .text ? "Cor do texto" : "Cor")
            Spacer()
            ColorPicker("", selection: Binding(get: { o.wrappedValue.color.color }, set: { o.wrappedValue.color = RGBA($0) })).labelsHidden()
        }
        if k != .text {
            SliderRow(title: "Espessura da linha", value: o.width, range: 1...16, shown: { "\(Int($0))" }, reset: 4)
        }
        SliderRow(title: k == .text ? "Opacidade do texto" : "Transparência", value: o.opacity, range: 0.1...1,
                  shown: { "\(Int(($0 * 100).rounded()))%" }, reset: 1)
        if k == .rect || k == .text {
            SliderRow(title: k == .text ? "Raio do fundo" : "Raio do canto", value: o.radius, range: 0...1, shown: { "\(Int(($0 * 100).rounded()))" })
        }
        if k == .text {
            HStack {
                Text("Cor de fundo")
                Spacer()
                ColorPicker("", selection: Binding(get: { o.wrappedValue.background.color }, set: { o.wrappedValue.background = RGBA($0) }),
                            supportsOpacity: true).labelsHidden()
            }
        }
        Button(role: .destructive) { m.deleteSelected() } label: { Label("Remover", systemImage: "trash") }
    }

    // MARK: Mosaico

    @ViewBuilder private var mosaic: some View {
        if let i = overlayIndex, m.settings.overlays[i].kind == .mosaic {
            let o = $m.settings.overlays[i]
            SectionTitle("Definições de Mosaico")
            SliderRow(title: "Força do Mosaico", value: o.width, range: 2...30, shown: { "\(Int($0))" }, reset: 8)
            SliderRow(title: "Bordas arredondadas", value: o.radius, range: 0...1, shown: { "\(Int(($0 * 100).rounded()))" }, reset: 0.1)
            Button {
                let v = o.wrappedValue
                for k in m.settings.overlays.indices where m.settings.overlays[k].kind == .mosaic {
                    m.settings.overlays[k].width = v.width; m.settings.overlays[k].radius = v.radius
                }
            } label: {
                Text("Aplicar a todos os mosaicos").frame(maxWidth: .infinity).frame(height: 40)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(role: .destructive) { m.deleteSelected() } label: { Label("Remover", systemImage: "trash") }
        } else {
            SectionTitle("Mosaico")
            Text("Esconde senhas, e-mails e outras informações. Arraste na prévia para cobrir a área; o mosaico acompanha o zoom.")
                .font(.callout).foregroundStyle(Theme.text2)
            Button { m.addOverlay(.mosaic) } label: { Label("Clique para adicionar desfoque", systemImage: "plus") }
                .controlSize(.large)
        }
    }

    // MARK: Teclas de atalho

    @ViewBuilder private var keys: some View {
        HStack {
            Text("Exibir teclas de atalho").font(.headline)
            Spacer()
            Toggle("", isOn: $m.settings.showKeys).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
        }
        if (m.events.keys ?? []).isEmpty {
            Text("Nenhum atalho detectado. Para registrar as teclas, o Foco precisa da permissão de Acessibilidade (Ajustes do Sistema › Privacidade e Segurança).")
                .font(.callout).foregroundStyle(Theme.text2)
        }
        Group {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Exibir Tecla de Atalho Única", isOn: $m.settings.keysSingle).toggleStyle(.switch).tint(Theme.accent)
                Text("Apenas combinações de teclas são exibidas por padrão. Teclas individuais também serão exibidas após a ativação.")
                    .font(.caption).foregroundStyle(Theme.text2)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Posição").foregroundStyle(Theme.text2)
                HStack(spacing: 8) {
                    Tile(selected: !m.settings.keysTop, radius: 8, action: { m.settings.keysTop = false }) { Text("Embaixo").padding(.vertical, 8) }
                        .frame(height: 36)
                    Tile(selected: m.settings.keysTop, radius: 8, action: { m.settings.keysTop = true }) { Text("Em cima").padding(.vertical, 8) }
                        .frame(height: 36)
                }
            }
            SliderRow(title: "Tamanho", value: $m.settings.keysSize, range: 0.5...2, shown: { String(format: "%.1fX", locale: .current, $0) }, reset: 1)
            HStack {
                Text("Cor da Fonte")
                Spacer()
                ColorPicker("", selection: Binding(get: { m.settings.keysColor.color }, set: { m.settings.keysColor = RGBA($0) })).labelsHidden()
            }
            HStack {
                Text("Cor de Fundo")
                Spacer()
                ColorPicker("", selection: Binding(get: { m.settings.keysBackground.color }, set: {
                    var c = RGBA($0); c.a = m.settings.keysBackground.a; m.settings.keysBackground = c
                }), supportsOpacity: false).labelsHidden()
            }
            SliderRow(title: "Opacidade do Plano de Fundo", value: $m.settings.keysBackground.a, range: 0...1,
                      shown: { "\(Int(($0 * 100).rounded()))%" }, reset: 0.7)
        }
        .disabled(!m.settings.showKeys).opacity(m.settings.showKeys ? 1 : 0.4)
    }

    // MARK: Clipe (como "Configurações do Clipe" do FocuSee)

    @ViewBuilder private func clipConfig(_ i: Int) -> some View {
        let c = $m.settings.clips[i]
        SectionTitle("Configurações do Clipe")
        SliderRow(title: "Velocidade", value: Binding(get: { c.wrappedValue.speed }, set: { c.wrappedValue.speed = ($0 * 10).rounded() / 10 }),
                  range: 0.5...6, shown: { String(format: "%gX", locale: .current, $0) }, reset: 1)
        Button {
            let s = c.wrappedValue.speed
            for k in m.settings.clips.indices { m.settings.clips[k].speed = s }
        } label: {
            Text("Aplicar a todos os clipes de vídeo").frame(maxWidth: .infinity).frame(height: 40)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        HStack {
            Text("Mostrar Cursor")
            Spacer()
            Toggle("", isOn: $m.settings.showCursor).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
        }
        if m.settings.showCursor {
            SliderRow(title: "Ângulo do cursor", value: $m.settings.cursorAngle, range: -45...45, shown: { "\(Int($0))°" }, reset: 0)
                .panelCard()
        }
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Áudio do clipe atual")
            Text("Ajuste individualmente o áudio do sistema e do microfone para o clipe de vídeo atual.")
                .font(.callout).foregroundStyle(Theme.text2)
        }
        SliderRow(title: "Áudio do Microfone", value: c.mic, range: 0...1, reset: 1)
        SliderRow(title: "Áudio do Sistema", value: c.system, range: 0...1, reset: 1)
    }

    // MARK: Trecho de digitação ("Acelerar" do FocuSee)

    @ViewBuilder private func typingConfig(_ k: Int) -> some View {
        let r = m.typing[k], cur = m.speed(of: r)
        SectionTitle("Acelerar")
        Text("Foi detectada digitação nesta parte da gravação. Você pode usar a opção abaixo para acelerar este trecho.")
            .font(.callout).foregroundStyle(Theme.text2)
        // FocuSee: de 1,5X a 8X, padrão 3X
        SliderRow(title: "Acelerar", value: $accelRate, range: 1.5...8, shown: { String(format: "%.1fX", locale: .current, $0) }, reset: 3)
        HStack {
            Button("Aplicar") { m.accelerate(r, speed: (accelRate * 10).rounded() / 10) }
                .buttonStyle(GradientButtonStyle()).frame(width: 120)
            Spacer()
            Button(role: .destructive) { m.accelerate(r, speed: 1) } label: { Label("Remover", systemImage: "arrow.uturn.backward") }
                .disabled(abs(cur - 1) < 0.01)
        }
        if abs(cur - 1) > 0.01 {
            Text("Este trecho está em \(String(format: "%gX", locale: .current, cur)).").font(.caption).foregroundStyle(Theme.text2)
        }
        Button {
            let v = (accelRate * 10).rounded() / 10
            for t in m.typing { m.accelerate(t, speed: v) }
        } label: {
            Text("Aplicar a todos os trechos de digitação").frame(maxWidth: .infinity).frame(height: 40)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Fileira de opções (como os botões de escolha do FocuSee)
    private func choices<T: Equatable>(_ items: [(String, T)], _ value: T, set: @escaping (T) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { k in
                Tile(selected: items[k].1 == value, radius: 8, action: { set(items[k].1) }) {
                    Text(items[k].0).font(.callout).lineLimit(1).minimumScaleFactor(0.7).padding(.vertical, 8)
                }
                .frame(height: 36)
            }
        }
    }

    // MARK: Fundo

    @ViewBuilder private var background: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tamanho da tela").foregroundStyle(Theme.text2)
            HStack(spacing: 6) {
                ForEach([Aspect.original, .wide, .square, .classic, .vertical], id: \.self) { a in
                    Tile(selected: m.settings.aspect == a, radius: 8, action: { m.settings.aspect = a }) {
                        Text(a.rawValue).font(.callout).padding(.vertical, 7)
                    }
                    .frame(height: 34)
                }
            }
            FieldMenu(label: Aspect.presets.first { $0.aspect == m.settings.aspect }?.name ?? "Plataforma") {
                ForEach(Aspect.presets, id: \.name) { p in
                    Button { m.settings.aspect = p.aspect } label: { Label(p.name, systemImage: p.icon) }
                }
            }
        }
        Divider()
        SliderRow(title: "Espaçamento interno", value: $m.settings.padding, range: 0...0.25)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Borda interna")
                Spacer()
                ColorPicker("", selection: Binding(get: { m.settings.insetColor.color }, set: { m.settings.insetColor = RGBA($0) }))
                    .labelsHidden()
                Text(String(Int((m.settings.inset * 10).rounded()))).foregroundStyle(Theme.text2).frame(minWidth: 34, alignment: .trailing)
            }
            .font(.callout)
            Slider(value: $m.settings.inset, in: 0...1).tint(Theme.accent)
        }
        SliderRow(title: "Bordas arredondadas", value: $m.settings.round, range: 0...0.25)
        SliderRow(title: "Sombra", value: $m.settings.shadow, range: 0...1)
        SliderRow(title: "Desfoque de fundo", value: $m.settings.blur, range: 0...1)

        VStack(alignment: .leading, spacing: 12) {
            Text("Fundo").foregroundStyle(Theme.text2)
            HStack(spacing: 18) {
                ForEach(Array(["Papéis de parede", "Degradês", "Cores", "Imagem"].enumerated()), id: \.offset) { i, t in
                    Button { bgTab = i } label: {
                        Text(t).font(.callout.weight(bgTab == i ? .semibold : .regular))
                            .foregroundStyle(bgTab == i ? .white : Theme.text2)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            switch bgTab {
            case 0:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(wallpapers, id: \.path) { w in
                        let sel = m.settings.bgKind == .wallpaper && m.settings.imagePath == w.path
                        Image(decorative: w.thumb, scale: 1).resizable().scaledToFill()
                            .frame(width: 52, height: 40).clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(sel ? Theme.accent : .clear, lineWidth: 2))
                            .onTapGesture { m.settings.bgKind = .wallpaper; m.settings.imagePath = w.path }
                    }
                }
                .task { if wallpapers.isEmpty { wallpapers = await Self.loadWallpapers() } }
            case 1:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(Settings.gradients.indices, id: \.self) { i in
                        let (a, b) = Settings.gradients[i]
                        let sel = m.settings.bgKind == .gradient && m.settings.gradient == i
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [a.color, b.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(sel ? Theme.accent : .clear, lineWidth: 2))
                            .onTapGesture { m.settings.bgKind = .gradient; m.settings.gradient = i }
                    }
                }
            case 2:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(Settings.colors.indices, id: \.self) { i in
                        let c = Settings.colors[i]
                        let sel = m.settings.bgKind == .color && m.settings.color == c
                        RoundedRectangle(cornerRadius: 8).fill(c.color).frame(height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(sel ? Theme.accent : Theme.stroke, lineWidth: sel ? 2 : 1))
                            .onTapGesture { m.settings.bgKind = .color; m.settings.color = c }
                    }
                }
                ColorPicker("Cor personalizada", selection: Binding(get: { m.settings.color.color },
                                                                    set: { m.settings.bgKind = .color; m.settings.color = RGBA($0) }))
            default:
                Button { pickImage() } label: { Label("Escolher imagem…", systemImage: "photo.badge.plus").frame(maxWidth: .infinity) }
                    .controlSize(.large)
                if m.settings.bgKind == .image, let p = m.settings.imagePath {
                    Text((p as NSString).lastPathComponent).font(.caption).foregroundStyle(Theme.text2)
                }
            }
        }
    }

    private func pickImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url { m.settings.bgKind = .image; m.settings.imagePath = u.path }
    }

    static func loadWallpapers() async -> [(path: String, thumb: CGImage)] {
        await Task.detached {
            let dirs = ["/System/Library/Desktop Pictures/.thumbnails", "/System/Library/Desktop Pictures"]
            let fm = FileManager.default
            let full = (try? fm.contentsOfDirectory(atPath: dirs[1])) ?? []
            let thumbs = Set((try? fm.contentsOfDirectory(atPath: dirs[0])) ?? [])
            // imagens estáticas (.heic) e as de .madesktop que têm miniatura com o mesmo nome
            var out: [(String, CGImage)] = []
            for name in full.sorted() {
                let base = (name as NSString).deletingPathExtension
                let path: String
                if name.hasSuffix(".heic") || name.hasSuffix(".jpg") || name.hasSuffix(".png") { path = "\(dirs[1])/\(name)" }
                else if thumbs.contains("\(base).heic") { path = "\(dirs[0])/\(base).heic" }
                else { continue }
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                           kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary)
                else { continue }
                out.append((path, cg))
            }
            return out
        }.value
    }

    // MARK: Cursor

    @ViewBuilder private var cursor: some View {
        HStack {
            Text("Mostrar Cursor").font(.headline)
            Spacer()
            Toggle("", isOn: $m.settings.showCursor).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
        }
        SliderRow(title: "Tamanho do Cursor", value: $m.settings.cursorSize, range: 1...6,
                  shown: { String(format: "%gX", locale: .current, ($0 * 2).rounded() / 2) }, reset: 3)
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Estilo do cursor")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(CursorStyles.names.indices, id: \.self) { i in
                    Tile(selected: m.settings.cursorStyle == i, action: { m.settings.cursorStyle = i }) {
                        CursorThumb(style: i)
                    }
                    .frame(height: 48)
                    .help(CursorStyles.names[i])
                }
            }
            .panelCard()
            Text("No estilo Sistema, a mãozinha e o cursor de texto aparecem como foram gravados.")
                .font(.caption).foregroundStyle(Theme.text2)
        }
        SliderRow(title: "Ângulo do cursor", value: $m.settings.cursorAngle, range: -45...45, shown: { "\(Int($0))°" }, reset: 0)
        SliderRow(title: "Direção dinâmica", value: $m.settings.cursorDirection, range: 0...45, shown: { "\(Int($0))°" }, reset: 0)
            .help("Ajusta automaticamente o ângulo de acordo com a direção do movimento do cursor, para um movimento mais natural.")
        Divider()

        // Efeito de clique: tipo, cor, opacidade e tamanho
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Efeito de Clique")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(ClickEffect.allCases) { e in
                    VStack(spacing: 6) {
                        Tile(selected: m.settings.click == e, action: { m.settings.click = e }) {
                            Image(systemName: Self.icon(e)).font(.system(size: 24))
                                .foregroundStyle(e == .sparkle ? Color.yellow : .white)
                        }
                        .frame(height: 58)
                        Text(e.title).font(.callout).foregroundStyle(m.settings.click == e ? .white : Theme.text2)
                    }
                }
            }
            if m.settings.click != .none {
                VStack(alignment: .leading, spacing: 14) {
                    if m.settings.click != .firework && m.settings.click != .spotlight {
                        HStack(spacing: 8) {
                            ForEach(Settings.clickColors.indices, id: \.self) { k in
                                let c = Settings.clickColors[k]
                                swatch(selected: !m.settings.clickRainbow && m.settings.clickColor == c, fill: AnyShapeStyle(c.color)) {
                                    m.settings.clickColor = c; m.settings.clickRainbow = false
                                }
                            }
                            swatch(selected: m.settings.clickRainbow,
                                   fill: AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))) {
                                m.settings.clickRainbow = true
                            }
                        }
                    }
                    SliderRow(title: "Opacidade", value: $m.settings.clickOpacity, range: 0.1...1, shown: { "\(Int(($0 * 100).rounded()))%" }, reset: 0.8)
                    SliderRow(title: "Tamanho", value: $m.settings.clickSize, range: 10...100, shown: { "\(Int($0))" }, reset: 50)
                }
                .panelCard()
            }
        }

        // Som de clique
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle("Som de clique")
                Spacer()
                Toggle("", isOn: $m.settings.clickSound).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
            }
            if m.settings.clickSound {
                HStack(spacing: 8) {
                    ForEach(Settings.clickSounds.indices, id: \.self) { k in
                        Tile(selected: m.settings.clickSoundID == k, radius: 8, action: {
                            m.settings.clickSoundID = k
                            NSSound(named: Settings.clickSounds[k].1)?.play()
                        }) { Text(Settings.clickSounds[k].0).padding(.vertical, 8) }
                        .frame(height: 36)
                    }
                }
                SliderRow(title: "Volume", value: $m.settings.clickVolume, range: 0...1, reset: 1)
            }
        }
        Divider()

        // Movimento do cursor (molas do FocuSee)
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Movimento do Cursor")
            HStack(spacing: 6) {
                ForEach(CursorMotion.allCases) { mo in
                    Tile(selected: m.settings.cursorMotion == mo, radius: 8, action: {
                        if mo == .custom, let s = m.settings.cursorMotion.spring { m.settings.cursorSpring = s }
                        m.settings.cursorMotion = mo
                    }) { Text(mo.rawValue).font(.callout).lineLimit(1).minimumScaleFactor(0.8).padding(.vertical, 8) }
                    .frame(height: 36)
                }
            }
            if m.settings.cursorMotion == .custom {
                VStack(spacing: 14) {
                    SliderRow(title: "Tensão", value: $m.settings.cursorSpring.stiffness, range: 50...1000, shown: { "\(Int($0))" }, reset: 470)
                        .help("A tensão acelera o movimento do cursor.")
                    SliderRow(title: "Fricção", value: $m.settings.cursorSpring.damping, range: 10...150, shown: { "\(Int($0))" }, reset: 70)
                        .help("O atrito desacelera o movimento do cursor e impede que ele passe do ponto.")
                    SliderRow(title: "Massa", value: $m.settings.cursorSpring.mass, range: 0.5...10, shown: { String(format: "%.1f", $0) }, reset: 3)
                        .help("A massa afeta o peso e a sensibilidade do movimento do cursor.")
                }
                .panelCard()
            }
            Toggle("Trajetória suave do cursor", isOn: $m.settings.smoothCursor).toggleStyle(.switch).tint(Theme.accent)
            SliderRow(title: "Desfoque de Movimento do Cursor", value: $m.settings.cursorBlur, range: 0...1, reset: 0.5)
        }
        Divider()

        // Inatividade e final do vídeo
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Ocultar Cursor Quando Inativo")
                Spacer()
                Toggle("", isOn: $m.settings.hideIdle).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
            }
            if m.settings.hideIdle {
                SliderRow(title: "Duração de inatividade do cursor", value: $m.settings.idleDuration, range: 1...10,
                          shown: { String(format: "%.1fs", locale: .current, $0) }, reset: 3)
            }
            Text("Posição do cursor no final do vídeo").foregroundStyle(Theme.text2)
            HStack(spacing: 8) {
                Tile(selected: !m.settings.endReturn, radius: 8, action: { m.settings.endReturn = false }) { Text("Manter atual").padding(.vertical, 8) }
                    .frame(height: 36)
                Tile(selected: m.settings.endReturn, radius: 8, action: { m.settings.endReturn = true }) { Text("Voltar ao início").padding(.vertical, 8) }
                    .frame(height: 36)
            }
            if m.settings.endReturn {
                SliderRow(title: "Duração antes do fim", value: $m.settings.endDuration, range: 0.5...5,
                          shown: { String(format: "%.1fs", locale: .current, $0) }, reset: 2)
            }
        }
    }

    private func swatch(selected: Bool, fill: AnyShapeStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7).fill(fill)
                .frame(width: 30, height: 30)
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    static func icon(_ e: ClickEffect) -> String {
        switch e {
        case .none: "nosign"
        case .regular: "cursorarrow.click"
        case .collapse: "arrow.down.right.and.arrow.up.left.circle"
        case .ripple: "dot.radiowaves.left.and.right"
        case .ring: "circle"
        case .diffusion: "circle.dotted.circle"
        case .spotlight: "flashlight.on.fill"
        case .sparkle: "sparkles"
        case .firework: "party.popper"
        }
    }

    // MARK: Zoom

    @ViewBuilder private var zoom: some View {
        if let i = m.settings.zooms.firstIndex(where: { $0.id == m.selected }) {
            zoomConfig(i)
        } else {
            zoomDefaults
        }
    }

    /// Painel "Configurações do Zoom" do bloco selecionado (como no FocuSee)
    @ViewBuilder private func zoomConfig(_ i: Int) -> some View {
        let z = $m.settings.zooms[i]
        SectionTitle("Configurações do Zoom")
        HStack {
            Text("Desativar Zoom")
            Spacer()
            Toggle("", isOn: Binding(get: { z.wrappedValue.off == true }, set: { z.wrappedValue.off = $0 ? true : nil }))
                .labelsHidden().toggleStyle(.switch).tint(Theme.accent)
        }
        Group {
            SliderRow(title: "Nível de Zoom", value: z.scale, range: 1.1...4,
                      shown: { String(format: "%.1fX", locale: .current, $0) }, reset: m.settings.zoomLevel)
            Button {
                let s = z.wrappedValue.scale
                for k in m.settings.zooms.indices { m.settings.zooms[k].scale = s }
            } label: {
                Text("Aplicar a todos os zooms").frame(maxWidth: .infinity).frame(height: 40)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            HStack(spacing: 10) {
                Tile(selected: z.wrappedValue.focus == nil, radius: 8, action: { z.wrappedValue.focus = nil }) {
                    Text("Automático").padding(.horizontal, 16).padding(.vertical, 8)
                }
                .fixedSize()
                Tile(selected: z.wrappedValue.focus != nil, radius: 8, action: {
                    if z.wrappedValue.focus == nil {
                        let c = m.events.samples.last { $0.t <= z.wrappedValue.a } ?? m.events.samples.first
                        z.wrappedValue.focus = [c?.x ?? 0.5, c?.y ?? 0.5]
                    }
                }) {
                    Text("Manual").padding(.horizontal, 16).padding(.vertical, 8)
                }
                .fixedSize()
            }
            if z.wrappedValue.focus == nil {
                Text("A imagem segue automaticamente o cursor e o mantém visível").font(.callout).foregroundStyle(Theme.text2)
            } else {
                Text("Arraste o quadro para escolher a área ampliada").font(.callout).foregroundStyle(Theme.text2)
                FocusPicker(zoom: z, video: m.project.raw, aspect: m.srcSize.width / max(m.srcSize.height, 1))
            }
            Divider()
            choices([("Zoom 2D", false), ("Zoom 3D", true)], z.wrappedValue.d3 == true) { z.wrappedValue.d3 = $0 ? true : nil }
            if z.wrappedValue.d3 == true { zoom3D(z) }
        }
        .disabled(z.wrappedValue.off == true).opacity(z.wrappedValue.off == true ? 0.4 : 1)
    }

    /// Painel do Zoom 3D (automático pela intensidade, ou manual com presets e eixos)
    @ViewBuilder private func zoom3D(_ z: Binding<Zoom>) -> some View {
        choices([("Automático", false), ("Manual", true)], z.wrappedValue.manual3D != nil) { manual in
            z.wrappedValue.manual3D = manual ? (z.wrappedValue.manual3D ?? [0, 25, 0, 35]) : nil
        }
        if let v = z.wrappedValue.manual3D {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Zoom3D.presets.indices, id: \.self) { k in
                    Tile(selected: Zoom3D.presets[k].1 == v, radius: 8, action: { z.wrappedValue.manual3D = Zoom3D.presets[k].1 }) {
                        Text(Zoom3D.presets[k].0).font(.caption).lineLimit(1).minimumScaleFactor(0.7).padding(.vertical, 8)
                    }
                    .frame(height: 34)
                }
            }
            let axis = { (i: Int) in Binding(get: { z.wrappedValue.manual3D?[i] ?? 0 }, set: { z.wrappedValue.manual3D?[i] = $0.rounded() }) }
            SliderRow(title: "Eixo X", value: axis(0), range: -80...80, shown: { "\(Int($0))°" }, reset: 0)
            SliderRow(title: "Eixo Y", value: axis(1), range: -60...60, shown: { "\(Int($0))°" }, reset: 0)
            SliderRow(title: "Eixo Z", value: axis(2), range: -90...90, shown: { "\(Int($0))°" }, reset: 0)
            SliderRow(title: "Campo de visão", value: axis(3), range: 30...53, shown: { "\(Int($0))°" }, reset: 35)
                .help("Quanto maior o campo de visão, mais forte a perspectiva.")
        } else {
            Text("Gera automaticamente movimento de câmera 3D com base nos cliques e movimentos do mouse").font(.callout).foregroundStyle(Theme.text2)
            Text("Intensidade").foregroundStyle(Theme.text2)
            choices([("Leve", 0), ("Padrão", 1), ("Forte", 2)], z.wrappedValue.effect ?? 1) { z.wrappedValue.effect = $0 }
        }
        Button {
            let src = z.wrappedValue
            for k in m.settings.zooms.indices {
                m.settings.zooms[k].d3 = true; m.settings.zooms[k].effect = src.effect; m.settings.zooms[k].manual3D = src.manual3D
            }
        } label: {
            Text("Aplicar a todos os efeitos 3D").frame(maxWidth: .infinity).frame(height: 40)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var zoomDefaults: some View {
        SectionTitle("Zoom automático")
        Text("Como no FocuSee: cada clique aproxima a tela e cliques a menos de 2,6 s um do outro ficam no mesmo zoom, que segue o mouse. Arraste os blocos azuis na linha do tempo para ajustar.")
            .font(.callout).foregroundStyle(Theme.text2)
        SliderRow(title: "Ampliação padrão", value: $m.settings.zoomLevel, range: 1.1...4, shown: { String(format: "%.1fx", $0) }, reset: 2)
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Zoom automático ao digitar", isOn: Binding(get: { m.settings.typingZoom }, set: { m.settings.typingZoom = $0; m.regenerateZooms() }))
                .toggleStyle(.switch).tint(Theme.accent)
            Text("Detecta a digitação durante a gravação e aproxima no cursor de texto. Mudar esta opção recria os zooms.")
                .font(.caption).foregroundStyle(Theme.text2)
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("Movimento da tela").foregroundStyle(Theme.text2)
            HStack(spacing: 8) {
                ForEach(Motion.allCases) { mo in
                    Tile(selected: m.settings.motion == mo, radius: 8, action: { m.settings.motion = mo }) { Text(mo.rawValue).padding(.vertical, 8) }
                        .frame(height: 36)
                }
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("Efeito de zoom automático").foregroundStyle(Theme.text2)
            choices(AutoZoomStyle.allCases.map { ($0.rawValue, $0) }, m.settings.autoZoomStyle) { m.settings.autoZoomStyle = $0; m.regenerateZooms() }
            if m.settings.autoZoomStyle == .d3 {
                Text("Intensidade").foregroundStyle(Theme.text2)
                choices([("Leve", 0), ("Padrão", 1), ("Forte", 2)], m.settings.effect3D) { m.settings.effect3D = $0; m.regenerateZooms() }
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle("Desfoque de Movimento")
                Spacer()
                Toggle("", isOn: $m.settings.motionBlur).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
            }
            if m.settings.motionBlur {
                SliderRow(title: "Desfoque de Movimento da Tela", value: $m.settings.screenMoveBlur, range: 0...1, reset: 0.5)
                SliderRow(title: "Desfoque ao aproximar", value: $m.settings.screenZoomBlur, range: 0...1, reset: 0.5)
                SliderRow(title: "Desfoque de Movimento do Cursor", value: $m.settings.cursorBlur, range: 0...1, reset: 0.5)
            }
        }
        HStack {
            Button { m.addZoom() } label: { Label("Adicionar zoom", systemImage: "plus") }
            Button { m.regenerateZooms() } label: { Label("Recriar pelos cliques", systemImage: "wand.and.stars") }
        }
        Text("\(m.settings.zooms.count) zooms na linha do tempo").font(.caption).foregroundStyle(Theme.text2)
    }

    // MARK: Câmera

    /// Molduras: nenhuma, cores sólidas e degradês
    static let frames: [[RGBA]?] = [nil, [RGBA(r: 1, g: 1, b: 1, a: 1)], [RGBA(r: 0.1, g: 0.1, b: 0.12, a: 1)],
                                    [RGBA(r: 0.80, g: 0.55, b: 0.98, a: 1), RGBA(r: 0.45, g: 0.40, b: 0.95, a: 1)],
                                    [RGBA(r: 0.55, g: 0.80, b: 1.00, a: 1), RGBA(r: 0.25, g: 0.55, b: 0.98, a: 1)],
                                    [RGBA(r: 1.0, g: 0.75, b: 0.35, a: 1), RGBA(r: 1.0, g: 0.35, b: 0.45, a: 1)],
                                    [RGBA(r: 0.45, g: 0.93, b: 0.75, a: 1), RGBA(r: 0.20, g: 0.70, b: 0.90, a: 1)]]

    @ViewBuilder private var camera: some View {
        if let i = overlayIndex, m.settings.overlays[i].kind.isLayout {
            let o = $m.settings.overlays[i]
            SectionTitle("Editar Layout")
            choices([("Tela cheia", Overlay.Kind.camFull), ("Sem câmera", .camNone)], o.wrappedValue.kind) { o.wrappedValue.kind = $0 }
            Toggle("Animação", isOn: Binding(get: { o.wrappedValue.transition ?? true }, set: { o.wrappedValue.transition = $0 })).toggleStyle(.switch).tint(Theme.accent)
            Text("Fora deste trecho vale o layout padrão.").font(.caption).foregroundStyle(Theme.text2)
            Button(role: .destructive) { m.deleteSelected() } label: { Label("Remover", systemImage: "trash") }
        } else {
            cameraDefaults
        }
    }

    @ViewBuilder private var cameraDefaults: some View {
        SectionTitle("Câmera")
        if m.project.camera == nil {
            Text("Esta gravação foi feita sem câmera. Escolha uma câmera em Equipamentos antes de gravar.")
                .font(.callout).foregroundStyle(Theme.text2)
        } else {
            Toggle("Mostrar câmera", isOn: $m.settings.showCamera).toggleStyle(.switch).tint(Theme.accent)
            SliderRow(title: "Tamanho", value: $m.settings.cameraSize, range: 0.15...0.7, reset: 0.35)
            SliderRow(title: "Arredondamento", value: $m.settings.cameraRound, range: 0...0.5, shown: { String(Int(($0 * 200).rounded())) })
            VStack(alignment: .leading, spacing: 10) {
                Text("Posição").foregroundStyle(Theme.text2)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach([(3, "Superior esquerdo"), (2, "Superior direito"), (1, "Inferior esquerdo"), (0, "Inferior direito")], id: \.0) { c, name in
                        Tile(selected: m.settings.cameraCorner == c, radius: 8, action: { m.settings.cameraCorner = c }) { Text(name).font(.callout).padding(.vertical, 8) }
                            .frame(height: 36)
                    }
                }
            }
            Toggle("Espelhar", isOn: $m.settings.cameraMirror).toggleStyle(.switch).tint(Theme.accent)
            Toggle("Diminuir durante o zoom", isOn: $m.settings.cameraShrinkOnZoom).toggleStyle(.switch).tint(Theme.accent)
            Divider()
            // Layout por trecho (faixa da linha do tempo)
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Layout")
                Text("Troca o layout num trecho do vídeo, a partir da agulha. Arraste o bloco verde na linha do tempo para ajustar.")
                    .font(.callout).foregroundStyle(Theme.text2)
                HStack {
                    Button { m.addOverlay(.camFull) } label: { Label("Tela cheia", systemImage: "person.crop.rectangle.fill") }
                    Button { m.addOverlay(.camNone) } label: { Label("Sem câmera", systemImage: "video.slash") }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Filtro")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(CameraFilter.allCases, id: \.self) { f in
                        Tile(selected: m.settings.cameraFilter == f, radius: 8, action: { m.settings.cameraFilter = f }) {
                            Text(f.rawValue).font(.caption).padding(.vertical, 8)
                        }
                        .frame(height: 34)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Moldura")
                HStack(spacing: 8) {
                    ForEach(Self.frames.indices, id: \.self) { k in
                        let f = Self.frames[k]
                        Button { m.settings.cameraBorder = f } label: {
                            Circle().fill(f.map { c in AnyShapeStyle(LinearGradient(colors: c.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing)) }
                                          ?? AnyShapeStyle(Theme.field))
                                .overlay(f == nil ? Image(systemName: "nosign").foregroundStyle(Theme.text2) : nil)
                                .frame(width: 28, height: 28).padding(3)
                                .overlay(Circle().stroke(m.settings.cameraBorder == f ? Theme.accent : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                    ColorPicker("", selection: Binding(get: { m.settings.cameraBorder?.first?.color ?? .white },
                                                      set: { m.settings.cameraBorder = [RGBA($0)] })).labelsHidden()
                }
            }
            HStack {
                Button { showCameraCrop = true } label: { Label("Recortar câmera…", systemImage: "crop") }
                if m.settings.cameraCrop != nil { Button("Desfazer recorte") { m.settings.cameraCrop = nil } }
            }
            .sheet(isPresented: $showCameraCrop) { CameraCropSheet(m: m) }
        }
    }
}

/// Quadro do vídeo no início do zoom com o retângulo da área ampliada (modo Manual)
struct FocusPicker: View {
    @Binding var zoom: Zoom
    let video: URL
    let aspect: CGFloat
    @State private var img: CGImage?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, vw = 1 / zoom.scale
            let clamp = { (v: Double) in min(max(v, vw / 2), 1 - vw / 2) }
            let cx = clamp(zoom.focus?[0] ?? 0.5), cy = clamp(zoom.focus?[1] ?? 0.5)
            ZStack(alignment: .topLeading) {
                if let img { Image(decorative: img, scale: 1).resizable() } else { Theme.field }
                Color.black.opacity(0.45)
                    .mask(Rectangle().overlay(Rectangle().frame(width: w * vw, height: h * vw)
                        .offset(x: (cx - vw / 2) * w, y: (cy - vw / 2) * h).blendMode(.destinationOut), alignment: .topLeading)
                        .compositingGroup())
                RoundedRectangle(cornerRadius: 3).stroke(Theme.accent, lineWidth: 2)
                    .frame(width: w * vw, height: h * vw)
                    .offset(x: (cx - vw / 2) * w, y: (cy - vw / 2) * h)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                zoom.focus = [clamp(v.location.x / w), clamp(v.location.y / h)]
            })
        }
        .aspectRatio(aspect, contentMode: .fit)
        .task(id: zoom.a) {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: video))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 640, height: 640)
            img = try? await g.image(at: CMTime(seconds: zoom.a + 0.05, preferredTimescale: 600)).image
        }
    }
}

struct CursorThumb: View {
    let style: Int
    @State private var img: CGImage?
    var body: some View {
        Group {
            if let img { Image(decorative: img, scale: 4).interpolation(.high) } else { Color.clear }
        }
        .task { img = CursorStyles.art(style).image }
    }
}

/// Alças da anotação ou do mosaico selecionado sobre a prévia (arrastar move; as bolinhas mudam os cantos/pontas)
struct OverlayEditor: View {
    @ObservedObject var m: EditorModel
    @State private var orig: (Overlay, CGPoint)?

    var body: some View {
        GeometryReader { geo in
            if let i = m.settings.overlays.firstIndex(where: { $0.id == m.selectedOverlay && !$0.kind.isLayout }), let r = m.renderer {
                let o = m.settings.overlays[i]
                let T = r.screenTransform(m.sourceTime), inv = T.inverted()
                let k = min(geo.size.width / r.out.width, geo.size.height / r.out.height)
                let ox = (geo.size.width - r.out.width * k) / 2, oy = (geo.size.height - r.out.height * k) / 2
                let toView = { (x: Double, y: Double) -> CGPoint in
                    let p = CGPoint(x: x * r.src.width, y: (1 - y) * r.src.height).applying(T)
                    return CGPoint(x: ox + p.x * k, y: oy + (r.out.height - p.y) * k)
                }
                let fromView = { (v: CGPoint) -> CGPoint in
                    let p = CGPoint(x: (v.x - ox) / k, y: r.out.height - (v.y - oy) / k).applying(inv)
                    return CGPoint(x: p.x / r.src.width, y: 1 - p.y / r.src.height)
                }
                let a = toView(o.p[0], o.p[1]), b = toView(o.p[2], o.p[3])
                let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                ZStack(alignment: .topLeading) {
                    Group {
                        if o.kind == .arrow || o.kind == .line {
                            Path { p in p.move(to: a); p.addLine(to: b) }
                                .stroke(Color.white.opacity(0.001), lineWidth: 24)
                                .overlay(Path { p in p.move(to: a); p.addLine(to: b) }.stroke(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [4])))
                        } else {
                            Rectangle().fill(Color.white.opacity(0.001))
                                .overlay(Rectangle().stroke(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [4])))
                                .frame(width: max(box.width, 8), height: max(box.height, 8))
                                .offset(x: box.minX, y: box.minY)
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("ov")).onChanged { v in
                        if orig?.0.id != o.id { orig = (o, fromView(v.startLocation)) }
                        guard let (o0, start) = orig else { return }
                        let now = fromView(v.location), dx = now.x - start.x, dy = now.y - start.y
                        m.settings.overlays[i].p = [o0.p[0] + dx, o0.p[1] + dy, o0.p[2] + dx, o0.p[3] + dy]
                    }.onEnded { _ in orig = nil })
                    knob(a) { v in let q = fromView(v); m.settings.overlays[i].p[0] = q.x; m.settings.overlays[i].p[1] = q.y }
                    knob(b) { v in let q = fromView(v); m.settings.overlays[i].p[2] = q.x; m.settings.overlays[i].p[3] = q.y }
                }
                .coordinateSpace(name: "ov")
            }
        }
    }

    private func knob(_ p: CGPoint, _ moved: @escaping (CGPoint) -> Void) -> some View {
        Circle().fill(.white).overlay(Circle().stroke(Theme.accent, lineWidth: 2))
            .frame(width: 12, height: 12)
            .offset(x: p.x - 6, y: p.y - 6)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("ov")).onChanged { moved($0.location) })
    }
}

/// "Recortar câmera": retângulo sobre um quadro da câmera (arrastar move; a bolinha muda o tamanho)
struct CameraCropSheet: View {
    @ObservedObject var m: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var img: CGImage?
    @State private var r = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var orig: CGRect?

    var body: some View {
        VStack(spacing: 16) {
            Text("Recortar Câmera").font(.title3.bold())
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack(alignment: .topLeading) {
                    if let img { Image(decorative: img, scale: 1).resizable() } else { Theme.field }
                    Color.black.opacity(0.5)
                        .mask(Rectangle().overlay(Rectangle().frame(width: r.width * w, height: r.height * h)
                            .offset(x: r.minX * w, y: r.minY * h).blendMode(.destinationOut), alignment: .topLeading).compositingGroup())
                    Rectangle().stroke(Theme.accent, lineWidth: 2)
                        .frame(width: r.width * w, height: r.height * h).offset(x: r.minX * w, y: r.minY * h)
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { v in
                            let o = orig ?? r; orig = o
                            r.origin = CGPoint(x: min(max(0, o.minX + v.translation.width / w), 1 - o.width),
                                               y: min(max(0, o.minY + v.translation.height / h), 1 - o.height))
                        }.onEnded { _ in orig = nil })
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .offset(x: r.maxX * w - 7, y: r.maxY * h - 7)
                        .gesture(DragGesture(coordinateSpace: .named("cc")).onChanged { v in
                            r.size = CGSize(width: min(max(0.15, v.location.x / w - r.minX), 1 - r.minX),
                                            height: min(max(0.15, v.location.y / h - r.minY), 1 - r.minY))
                        })
                }
                .coordinateSpace(name: "cc")
            }
            .aspectRatio(img.map { CGFloat($0.width) / CGFloat($0.height) } ?? 16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Redefinir") { r = CGRect(x: 0, y: 0, width: 1, height: 1) }
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Aplicar") {
                    m.settings.cameraCrop = r.width > 0.99 && r.height > 0.99 ? nil : [r.minX, r.minY, r.width, r.height]
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 640)
        .onAppear { if let c = m.settings.cameraCrop { r = CGRect(x: c[0], y: c[1], width: c[2], height: c[3]) } }
        .task {
            guard let u = m.project.camera else { return }
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: u))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 1280, height: 1280)
            img = try? await g.image(at: CMTime(seconds: max(0, m.sourceTime - (m.events.cameraOffset ?? 0)), preferredTimescale: 600)).image
        }
    }
}

// MARK: - Linha do tempo

struct TimelineStrip: View {
    @ObservedObject var m: EditorModel
    @State private var zoomOrig: (Zoom, Double, Double)? // zoom + início e fim no vídeo final
    @State private var clipOrig: (Clip, CGFloat)?        // clipe + escala no início do arraste
    @State private var ovOrig: (Overlay, Double, Double)? // anotação + início e fim no vídeo final
    @State private var scroll = ScrollPosition(edge: .leading)

    private enum Edge { case move, start, end }
    private let inset: CGFloat = 20, clipY: CGFloat = 34, clipH: CGFloat = 56, zoomY: CGFloat = 104, zoomH: CGFloat = 44,
                ovY: CGFloat = 156, ovH: CGFloat = 60

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.width * m.tlZoom
            let w = max(full - inset * 2, 10)
            let pps = w / m.total
            let x = { (t: Double) in inset + t * pps }
            let toT = { (px: CGFloat) in min(max((px - inset) / pps, 0), m.total) }

            ZStack(alignment: .topLeading) {
                ruler(pps: pps)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("tl")).onChanged { m.seek(toT($0.location.x)) })

                // clipes roxos com a onda do áudio, um após o outro no tempo do vídeo final
                ForEach(Array(m.clips.enumerated()), id: \.element.id) { i, c in
                    let cx = x(m.clips.start(i)), cw = max(4, c.len * pps - 2)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 10).fill(Theme.clip)
                        Waveform(peaks: m.wave, from: c.a / max(m.duration, 0.1), to: c.b / max(m.duration, 0.1))
                            .fill(Color.white.opacity(0.22))
                            .padding(.top, 22)
                        HStack(spacing: 8) {
                            Image(systemName: "play.rectangle").font(.caption)
                            Text("Clip \(Int(c.len.rounded()))s").font(.caption.bold())
                            Text(String(format: "%gX", locale: .current, c.speed)).font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.horizontal, 12).padding(.top, 6).opacity(cw > 120 ? 1 : 0)
                    }
                    .frame(width: cw, height: clipH)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: c.id == m.selectedClip ? 2 : 0))
                    .offset(x: cx, y: clipY)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("tl")).onChanged {
                        if m.selectedClip != c.id { m.selectedClip = c.id }
                        m.seek(toT($0.location.x))
                    })
                    if cw > 30 {
                        clipHandle(at: cx + 4, id: c.id, pps: pps, isStart: true)
                        clipHandle(at: cx + cw - 12, id: c.id, pps: pps, isStart: false)
                    }
                }

                // trechos de digitação, na base dos clipes (clique para acelerar)
                ForEach(Array(m.typing.enumerated()), id: \.offset) { k, r in
                    let oa = m.clips.output(r.0), ob = m.clips.output(r.1)
                    if ob - oa > 0.05 {
                        let sel = m.selectedTyping == k
                        Label("Digitação", systemImage: "keyboard").font(.system(size: 9, weight: .bold)).lineLimit(1)
                            .foregroundStyle(.black.opacity(0.75)).padding(.horizontal, 4)
                            .frame(width: max(8, (ob - oa) * pps), height: 14, alignment: .leading)
                            .background(Color(red: 1, green: 0.82, blue: 0.3).opacity(sel ? 1 : 0.8), in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white, lineWidth: sel ? 1.5 : 0))
                            .clipped()
                            .offset(x: x(oa), y: clipY + clipH - 17)
                            .onTapGesture { m.selectedTyping = k }
                            .help("Trecho de digitação: clique para acelerar")
                    }
                }

                // trilha de zoom (os zooms ficam presos ao trecho da gravação; num trecho apagado somem)
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04))
                    .frame(width: w, height: zoomH).offset(x: inset, y: zoomY)
                    .gesture(SpatialTapGesture(coordinateSpace: .named("tl")).onEnded { m.addZoom(at: toT($0.location.x)) })
                if m.settings.zooms.isEmpty {
                    Label("Clique aqui para adicionar zoom", systemImage: "plus.circle")
                        .foregroundStyle(Theme.text2).frame(width: w, height: zoomH).offset(x: inset, y: zoomY)
                        .allowsHitTesting(false)
                }
                ForEach(m.settings.zooms) { z in
                    let oa = m.clips.output(z.a), ob = m.clips.output(z.b)
                    if ob - oa > 0.05 {
                        let sel = z.id == m.selected
                        let bw = max(10, (ob - oa) * pps)
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Theme.zoom)
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white, lineWidth: sel ? 2 : 0))
                            .overlay(
                                Label("Zoom \(z.d3 == true ? "3D " : "")\(z.scale, format: .number.precision(.fractionLength(1)))X",
                                      systemImage: z.d3 == true ? "cube.transparent" : "plus.magnifyingglass")
                                    .font(.caption.bold()).foregroundStyle(.white).lineLimit(1).opacity(bw > 60 ? 1 : 0)
                            )
                            .opacity(z.off == true ? 0.35 : sel ? 1 : 0.85)
                            .frame(width: bw, height: zoomH)
                            .offset(x: x(oa), y: zoomY)
                            .onTapGesture { m.selected = z.id }
                            .gesture(dragZoom(z, .move, pps))
                        edgeHandle(x: x(oa)).gesture(dragZoom(z, .start, pps))
                        edgeHandle(x: x(ob)).gesture(dragZoom(z, .end, pps))
                    }
                }

                // trilha de anotações e mosaicos
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04))
                    .frame(width: w, height: ovH).offset(x: inset, y: ovY)
                if m.settings.overlays.isEmpty {
                    Text("Anotações, mosaicos e layouts da câmera aparecem aqui").font(.caption)
                        .foregroundStyle(Theme.text2).frame(width: w, height: ovH).offset(x: inset, y: ovY)
                        .allowsHitTesting(false)
                }
                let rows = Self.rows(m.settings.overlays), rowH = min(30, ovH / CGFloat(max(1, (rows.values.max() ?? 0) + 1)))
                ForEach(m.settings.overlays) { o in
                    let oa = m.clips.output(o.a), ob = m.clips.output(o.b)
                    let y = ovY + CGFloat(rows[o.id] ?? 0) * rowH
                    if ob - oa > 0.05 {
                        let sel = o.id == m.selectedOverlay
                        let bw = max(10, (ob - oa) * pps)
                        RoundedRectangle(cornerRadius: 7)
                            .fill(o.kind.isLayout ? Color(red: 0.2, green: 0.7, blue: 0.45)
                                  : o.kind == .mosaic ? Color(red: 0.45, green: 0.47, blue: 0.55) : Color(red: 0.95, green: 0.55, blue: 0.2))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white, lineWidth: sel ? 2 : 0))
                            .overlay(
                                Label(o.kind == .text ? o.text : o.kind.rawValue, systemImage: Inspector.icon(o.kind))
                                    .font(.caption.bold()).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 6).opacity(bw > 50 ? 1 : 0)
                            )
                            .opacity(sel ? 1 : 0.85)
                            .frame(width: bw, height: rowH - 2)
                            .offset(x: x(oa), y: y)
                            .onTapGesture { m.selectedOverlay = o.id }
                            .gesture(dragOverlay(o, .move, pps))
                        edgeHandle(x: x(oa), y: y, h: rowH - 2).gesture(dragOverlay(o, .start, pps))
                        edgeHandle(x: x(ob), y: y, h: rowH - 2).gesture(dragOverlay(o, .end, pps))
                    }
                }

                // agulha de reprodução
                Rectangle().fill(Theme.playhead).frame(width: 2, height: geo.size.height - 6)
                    .offset(x: x(m.time) - 1, y: 4)
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 3).fill(Theme.playhead).frame(width: 12, height: 14).offset(x: x(m.time) - 6, y: 0).allowsHitTesting(false)
            }
            .coordinateSpace(name: "tl")
            .frame(width: full, height: geo.size.height, alignment: .topLeading)
            .horizontalScroll($scroll)
            // ao mudar o zoom, mantém a agulha no meio
            .onChange(of: m.tlZoom) { scroll.scrollTo(x: max(0, x(m.time) - geo.size.width / 2)) }
        }
        .padding(.vertical, 10)
        .background(Theme.panel)
    }

    private func ruler(pps: CGFloat) -> some View {
        let d = m.total, visible = d / m.tlZoom // marcas conforme o trecho visível
        let step: Double = visible <= 4 ? 0.5 : visible <= 15 ? 1 : visible <= 60 ? 5 : visible <= 300 ? 15 : 60
        return Canvas { ctx, size in
            var t = 0.0
            while t <= d + 0.001 {
                let px = inset + t * pps
                ctx.fill(Path(CGRect(x: px, y: 18, width: 1, height: 6)), with: .color(.white.opacity(0.3)))
                ctx.draw(Text(step < 1 ? String(format: "%gs", locale: .current, t) : "\(Int(t))s").font(.system(size: 10)).foregroundColor(.white.opacity(0.5)), at: CGPoint(x: px, y: 8))
                t += step
            }
        }
        .frame(height: 26)
    }

    private func edgeHandle(x: CGFloat, y: CGFloat? = nil, h: CGFloat? = nil) -> some View {
        Rectangle().fill(.white.opacity(0.001))
            .frame(width: 12, height: h ?? zoomH)
            .offset(x: x - 6, y: y ?? zoomY)
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
    }

    /// Arrasta no tempo do vídeo final e converte de volta para o tempo da gravação
    private func dragZoom(_ z: Zoom, _ edge: Edge, _ pps: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("tl"))
            .onChanged { v in
                if zoomOrig?.0.id != z.id { zoomOrig = (z, m.clips.output(z.a), m.clips.output(z.b)) }
                guard let (o, oa, ob) = zoomOrig, let i = m.settings.zooms.firstIndex(where: { $0.id == z.id }) else { return }
                let dt = v.translation.width / pps
                var na = oa, nb = ob
                switch edge {
                case .move:
                    let d = min(max(dt, -oa), m.total - ob)
                    na += d; nb += d
                case .start: na = min(max(0, oa + dt), ob - 0.3)
                case .end: nb = max(min(m.total, ob + dt), oa + 0.3)
                }
                var n = o
                n.a = m.clips.source(na).1; n.b = m.clips.source(nb).1
                m.settings.zooms[i] = n
                m.selected = z.id
            }
            .onEnded { _ in zoomOrig = nil }
    }

    /// Linha de cada anotação na trilha: as que se sobrepõem no tempo vão para linhas diferentes
    static func rows(_ ovs: [Overlay]) -> [UUID: Int] {
        var ends: [Double] = [], out: [UUID: Int] = [:]
        for o in ovs.sorted(by: { $0.a < $1.a }) {
            let r = ends.firstIndex { $0 <= o.a } ?? { ends.append(0); return ends.count - 1 }()
            ends[r] = o.b; out[o.id] = r
        }
        return out
    }

    private func dragOverlay(_ o: Overlay, _ edge: Edge, _ pps: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("tl"))
            .onChanged { v in
                if ovOrig?.0.id != o.id { ovOrig = (o, m.clips.output(o.a), m.clips.output(o.b)) }
                guard let (orig, oa, ob) = ovOrig, let i = m.settings.overlays.firstIndex(where: { $0.id == o.id }) else { return }
                let dt = v.translation.width / pps
                var na = oa, nb = ob
                switch edge {
                case .move:
                    let d = min(max(dt, -oa), m.total - ob)
                    na += d; nb += d
                case .start: na = min(max(0, oa + dt), ob - 0.3)
                case .end: nb = max(min(m.total, ob + dt), oa + 0.3)
                }
                var n = orig
                n.a = m.clips.source(na).1; n.b = m.clips.source(nb).1
                m.settings.overlays[i] = n
                m.selectedOverlay = o.id
            }
            .onEnded { _ in ovOrig = nil }
    }

    /// Alças brancas: aparam o início ou o fim do clipe (sem invadir os vizinhos)
    private func clipHandle(at px: CGFloat, id: UUID, pps: CGFloat, isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(.white)
            .frame(width: 8, height: clipH - 16)
            .offset(x: px, y: clipY + 8)
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("tl"))
                .onChanged { v in
                    guard let i = m.clips.firstIndex(where: { $0.id == id }) else { return }
                    if clipOrig?.0.id != id { clipOrig = (m.clips[i], pps) }
                    guard let (o, p0) = clipOrig else { return }
                    let ds = v.translation.width / p0 * o.speed // segundos da gravação
                    let lo = i > 0 ? m.clips[i - 1].b : 0, hi = i + 1 < m.clips.count ? m.clips[i + 1].a : m.duration
                    if isStart {
                        m.settings.clips[i].a = min(max(lo, o.a + ds), o.b - 0.3)
                        m.seek(m.clips.start(i))
                    } else {
                        m.settings.clips[i].b = max(min(hi, o.b + ds), o.a + 0.3)
                        m.seek(m.clips.start(i) + m.clips[i].len - 0.02)
                    }
                    m.selectedClip = id
                }
                .onEnded { _ in clipOrig = nil })
    }
}

struct Waveform: Shape {
    let peaks: [Float]
    let from: Double, to: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard peaks.count > 1, to > from else { return p }
        let i0 = min(Int(from * Double(peaks.count)), peaks.count - 1)
        let i1 = max(i0 + 1, min(peaks.count, Int(to * Double(peaks.count))))
        let slice = peaks[i0..<i1]
        let step = r.width / CGFloat(slice.count)
        p.move(to: CGPoint(x: 0, y: r.maxY))
        for (k, v) in slice.enumerated() { p.addLine(to: CGPoint(x: CGFloat(k) * step, y: r.maxY - CGFloat(v) * r.height)) }
        p.addLine(to: CGPoint(x: r.width, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Exportação

struct ExportSheet: View {
    @ObservedObject var m: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var o = ExportOptions.saved
    @State private var name = ""
    @State private var remember = false
    @State private var started = false

    private var duration: Double { m.total }
    private var size: CGSize { outputSize(m.inputs, src: m.srcSize, shortSide: o.shortSide) }
    private var estimate: String {
        let bytes: Double
        if o.format == .gif { bytes = size.width * size.height * duration * Double(o.fps) * 0.12 }
        else { bytes = (size.width * size.height * Double(o.fps) * o.quality.bitsPerPixel + 160_000) * duration / 8 }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Exportar Vídeo").font(.title2.bold()).frame(maxWidth: .infinity)
            field("Nome") {
                TextField("", text: $name).textFieldStyle(.plain)
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
            }
            field("Salvar em") {
                HStack {
                    Text(o.folder).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button { pickFolder() } label: { Image(systemName: "folder") }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
            }
            HStack(alignment: .top, spacing: 16) {
                field("Formato") {
                    FieldMenu(label: o.format.rawValue) {
                        ForEach(ExportOptions.Format.allCases, id: \.self) { f in
                            Button(f.rawValue) { o.format = f; if f == .gif && o.fps > 20 { o.fps = 20 } }
                        }
                    }
                }
                field("Resolução") {
                    FieldMenu(label: resLabel(o.shortSide)) {
                        ForEach(ExportOptions.resolutions, id: \.0) { r in Button(resLabel(r.1)) { o.shortSide = r.1 } }
                    }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                field("Taxa de quadros") {
                    FieldMenu(label: "\(o.fps)FPS") {
                        ForEach(ExportOptions.frameRates, id: \.self) { f in Button("\(f)FPS") { o.fps = f } }
                    }
                }
                field("Qualidade") {
                    FieldMenu(label: o.quality.rawValue) {
                        ForEach(ExportOptions.Quality.allCases, id: \.self) { q in Button(q.rawValue) { o.quality = q } }
                        Divider()
                        Text("Quanto maior a qualidade, mais nítida a imagem e maior o arquivo.")
                    }
                    .disabled(o.format == .gif)
                }
            }
            if let p = m.exportProgress {
                VStack(spacing: 6) {
                    ProgressView(value: p).tint(Theme.accent)
                    Text("Exportando… \(Int(p * 100))%").font(.callout).foregroundStyle(Theme.text2)
                }
                .frame(height: 44)
            } else {
                Button("Exportar") {
                    started = true
                    if remember { o.save() }
                    m.export(o, name: name.isEmpty ? m.project.name : name)
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            HStack {
                Toggle("Salvar configurações atuais", isOn: $remember).toggleStyle(.checkbox)
                Spacer()
                Text("(Tamanho estimado: \(estimate))").foregroundStyle(Theme.text2)
            }
            .font(.callout)
        }
        .padding(28)
        .frame(width: 560)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                    .frame(width: 28, height: 28).background(Theme.field, in: Circle())
            }
            .buttonStyle(.plain).padding(14)
            .disabled(m.exportProgress != nil)
        }
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .onAppear { name = m.project.name }
        .onChange(of: m.exportProgress == nil) { _, finished in if finished && started { dismiss() } }
        .onExitCommand { if m.exportProgress == nil { dismiss() } }
    }

    private func resLabel(_ side: Double?) -> String {
        let s = outputSize(m.inputs, src: m.srcSize, shortSide: side)
        let name = ExportOptions.resolutions.first { $0.1 == side }?.0 ?? "Original"
        return "\(name) (\(Int(s.width)) * \(Int(s.height)))"
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).foregroundStyle(Theme.text2)
            c()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: o.folder)
        if p.runModal() == .OK, let u = p.url { o.folder = u.path }
    }
}

// MARK: - Cortar Vídeo (recorte da área da tela, como no FocuSee)

struct CropSheet: View {
    @ObservedObject var m: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var r = CGRect(x: 0, y: 0, width: 1, height: 1) // normalizado, y para baixo
    @State private var ratio: Double?                                // largura/altura em pixels; nil = Personalizado
    @State private var start: CGRect?
    @State private var img: CGImage?

    private enum H { case move, l, r, t, b, tl, tr, bl, br }
    private static let ratios: [(String, Double?)] = [("Personalizado", nil), ("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("1:1", 1), ("9:16", 9.0 / 16)]
    private let cyan = Color(red: 0.2, green: 0.85, blue: 0.95)

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Text("Cortar Vídeo").font(.title2.bold())
                HStack {
                    Button { dismiss() } label: { Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 13, height: 13) }
                        .buttonStyle(.plain).help("Fechar")
                    Spacer()
                }
            }
            HStack(spacing: 10) {
                ForEach(Self.ratios, id: \.0) { name, q in
                    Tile(selected: ratio == q, radius: 8, action: { setRatio(q) }) {
                        Text(name).padding(.horizontal, 14).padding(.vertical, 7)
                    }
                    .fixedSize()
                }
                Spacer()
                Text(verbatim: "Tamanho: \(Int(r.width * m.srcSize.width))*\(Int(r.height * m.srcSize.height))px").foregroundStyle(Theme.text2)
            }
            GeometryReader { geo in
                let aspect = m.srcSize.width / max(m.srcSize.height, 1)
                let fw = min(geo.size.width, geo.size.height * aspect), fh = fw / aspect
                editor(CGSize(width: fw, height: fh))
                    .frame(width: fw, height: fh)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .padding(18)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            .frame(height: 440)
            HStack(spacing: 14) {
                Spacer()
                Button { dismiss() } label: {
                    Text("Cancelar").font(.headline).frame(width: 140, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                Button("Aplicar") {
                    let full = r.minX < 0.001 && r.minY < 0.001 && r.width > 0.999 && r.height > 0.999
                    m.settings.crop = full ? nil : [r.minX, r.minY, r.width, r.height]
                    dismiss()
                }
                .buttonStyle(GradientButtonStyle()).frame(width: 160).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 820)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .onAppear { r = m.settings.cropRect }
        .task {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: m.project.raw))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 1600, height: 1600)
            img = try? await g.image(at: CMTime(seconds: m.sourceTime, preferredTimescale: 600)).image
        }
    }

    private func editor(_ s: CGSize) -> some View {
        let R = CGRect(x: r.minX * s.width, y: r.minY * s.height, width: r.width * s.width, height: r.height * s.height)
        let handles: [H] = ratio == nil ? [.tl, .tr, .bl, .br, .l, .r, .t, .b] : [.tl, .tr, .bl, .br]
        return ZStack(alignment: .topLeading) {
            if let img { Image(decorative: img, scale: 1).resizable() } else { Theme.field }
            Path { p in p.addRect(CGRect(origin: .zero, size: s)); p.addRect(R) }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            Path { p in // regra dos terços
                for k in 1...2 {
                    let fx = R.minX + R.width * CGFloat(k) / 3, fy = R.minY + R.height * CGFloat(k) / 3
                    p.move(to: CGPoint(x: fx, y: R.minY)); p.addLine(to: CGPoint(x: fx, y: R.maxY))
                    p.move(to: CGPoint(x: R.minX, y: fy)); p.addLine(to: CGPoint(x: R.maxX, y: fy))
                }
            }
            .stroke(cyan, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            Path(R).stroke(cyan, lineWidth: 1.5)
            Color.white.opacity(0.001)
                .frame(width: R.width, height: R.height)
                .position(x: R.midX, y: R.midY)
                .gesture(drag(.move, s))
            ForEach(handles, id: \.self) { h in handle(h, R).gesture(drag(h, s)) }
        }
        .frame(width: s.width, height: s.height)
    }

    private func handle(_ h: H, _ R: CGRect) -> some View {
        let x: CGFloat = [.l, .tl, .bl].contains(h) ? R.minX : [.r, .tr, .br].contains(h) ? R.maxX : R.midX
        let y: CGFloat = [.t, .tl, .tr].contains(h) ? R.minY : [.b, .bl, .br].contains(h) ? R.maxY : R.midY
        let corner = [.tl, .tr, .bl, .br].contains(h)
        return ZStack {
            if corner {
                Path { p in p.move(to: CGPoint(x: 13, y: 29)); p.addLine(to: CGPoint(x: 13, y: 13)); p.addLine(to: CGPoint(x: 29, y: 13)) }
                    .stroke(cyan, style: StrokeStyle(lineWidth: 4, lineCap: .square))
                    .scaleEffect(x: [.tr, .br].contains(h) ? -1 : 1, y: [.bl, .br].contains(h) ? -1 : 1)
            } else {
                let horiz = h == .t || h == .b
                Rectangle().fill(cyan).frame(width: horiz ? 20 : 4, height: horiz ? 4 : 20)
            }
        }
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
        .position(x: x, y: y)
    }

    private func drag(_ h: H, _ s: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if start == nil { start = r }
                guard let o = start else { return }
                r = resize(o, h, v.translation.width / s.width, v.translation.height / s.height)
            }
            .onEnded { _ in start = nil }
    }

    private func resize(_ o: CGRect, _ h: H, _ dx: CGFloat, _ dy: CGFloat) -> CGRect {
        if h == .move {
            return o.offsetBy(dx: min(max(dx, -o.minX), 1 - o.maxX), dy: min(max(dy, -o.minY), 1 - o.maxY))
        }
        let minS: CGFloat = 0.05
        let left = [.l, .tl, .bl].contains(h), right = [.r, .tr, .br].contains(h)
        let top = [.t, .tl, .tr].contains(h), bottom = [.b, .bl, .br].contains(h)
        var x0 = o.minX, y0 = o.minY, x1 = o.maxX, y1 = o.maxY
        if left { x0 = min(max(0, x0 + dx), x1 - minS) }
        if right { x1 = max(min(1, x1 + dx), x0 + minS) }
        if top { y0 = min(max(0, y0 + dy), y1 - minS) }
        if bottom { y1 = max(min(1, y1 + dy), y0 + minS) }
        guard let q = ratio else { return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) }
        // proporção fixa: a largura manda e a altura acompanha, presa ao canto oposto
        let k = q * m.srcSize.height / m.srcSize.width
        var w = x1 - x0, hh = w / k
        let maxH = top ? o.maxY : 1 - o.minY
        if hh > maxH { hh = maxH; w = hh * k }
        return CGRect(x: left ? o.maxX - w : o.minX, y: top ? o.maxY - hh : o.minY, width: w, height: hh)
    }

    private func setRatio(_ q: Double?) {
        ratio = q
        guard let q else { return }
        let k = q * m.srcSize.height / m.srcSize.width // largura/altura normalizadas
        let (w, h) = k > 1 ? (1.0, 1 / k) : (k, 1.0)
        r = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}

extension View {
    /// rolagem horizontal com posição controlável (linha do tempo com zoom)
    func horizontalScroll(_ position: Binding<ScrollPosition>) -> some View {
        ScrollView(.horizontal) { self }.scrollPosition(position)
    }
}
