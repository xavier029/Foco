import SwiftUI
import ScreenCaptureKit
import AVFoundation
import Carbon.HIToolbox

enum CaptureMode: String, CaseIterable, Identifiable {
    case screen = "Tela inteira", window = "Janela", area = "Área"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .screen: "display"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        }
    }
}

enum RecState: Equatable { case idle, countdown(Int), recording, saving }

extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }
}

/// Qualidade da gravação (FocuSee: só muda o bitrate, ×1,2 / ×1,0 / ×0,9 / ×0,8; padrão Alto)
enum RecordQuality: String, CaseIterable, Identifiable {
    case ultra = "Ultra", high = "Alto", medium = "Médio", low = "Baixo"
    var id: String { rawValue }
    var factor: Double { switch self { case .ultra: 1.2; case .high: 1.0; case .medium: 0.9; case .low: 0.8 } }
}

@MainActor
final class Recorder: NSObject, ObservableObject {
    static let shared = Recorder()

    @Published var mode = CaptureMode.screen
    @Published var windowID: CGWindowID?
    // nil = "Nenhum". As escolhas ficam salvas entre aberturas do app.
    @Published var cameraID = Recorder.saved("cameraID", default: nil) { didSet { UserDefaults.standard.set(cameraID ?? "none", forKey: "cameraID") } }
    @Published var micID = Recorder.saved("micID", default: AVCaptureDevice.default(for: .audio)?.uniqueID) {
        didSet { UserDefaults.standard.set(micID ?? "none", forKey: "micID") }
    }
    @Published var systemAudio = UserDefaults.standard.object(forKey: "systemAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(systemAudio, forKey: "systemAudio") }
    }
    @Published var windows: [SCWindow] = []
    @Published var cameras: [AVCaptureDevice] = []
    @Published var mics: [AVCaptureDevice] = []
    @Published var state = RecState.idle
    @Published var canCapture = CGPreflightScreenCaptureAccess()
    @Published var elapsed = 0
    @Published var lastError: String?
    @Published var paused = false
    @Published var quality = RecordQuality(rawValue: UserDefaults.standard.string(forKey: "recordQuality") ?? "") ?? .high {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "recordQuality") }
    }
    // Contagem regressiva pré-gravação, em segundos (0, 3 ou 5, como no FocuSee)
    @Published var countdown = UserDefaults.standard.object(forKey: "countdown") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(countdown, forKey: "countdown") }
    }
    var onFinished: ((URL) -> Void)?

    private var stream: SCStream?
    private var writer: ScreenWriter?
    private var cancelled = false
    private var camera: CameraRecorder?
    private var dir: URL?
    private var region = CGRect.zero // área gravada, em coordenadas globais (origem no topo)
    private var scale = 2.0
    private var t0: Date?
    private var moves: [(Date, CGPoint, Int?)] = []
    // formatos de cursor vistos na gravação (como o cursors.json do FocuSee)
    private var shapes: [CursorShape] = []
    private var shapeKeys: [String: Int] = [:]
    private var currentShape: Int?
    private var tick = 0
    private var lastApp: String?
    // Pausa: a gravação continua no arquivo e os trechos pausados viram cortes entre clipes no editor
    private var pausedAt: Date?
    private var pauses: [(Date, Date)] = []
    private var lastArea: CGRect?
    private var reuseArea = false // "Reiniciar" grava de novo a mesma área
    private var appObserver: Any?

    override init() {
        super.init()
        if let f = NSWorkspace.shared.frontmostApplication, f.bundleIdentifier != Bundle.main.bundleIdentifier { lastApp = f.localizedName }
        // lembra o último app usado (fora o Foco) para dar nome à gravação
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.bundleIdentifier != Bundle.main.bundleIdentifier { self?.lastApp = app.localizedName }
            }
        }
    }
    private var clicks: [Date] = []
    private var keys: [(Date, String, Bool, CGPoint?)] = []
    private var keyMonitor: Any?
    private static var askedAX = false
    private var timer: Timer?
    private var clickMonitor: Any?
    private var panels: [NSPanel] = []
    private var hiddenWindows: [NSWindow] = []
    private var countPanel: NSPanel?

    func requestCapturePermission() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func refreshSources() async {
        canCapture = CGPreflightScreenCaptureAccess()
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                   mediaType: .video, position: .unspecified).devices
        mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        if let c = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) {
            windows = c.windows.filter {
                $0.windowLayer == 0 && !($0.title ?? "").isEmpty && $0.frame.width > 120
                    && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
            }
        }
    }

    private static func saved(_ key: String, default d: String?) -> String? {
        guard let v = UserDefaults.standard.string(forKey: key) else { return d }
        return v == "none" ? nil : v
    }

    func thumbnail(_ w: SCWindow) async -> CGImage? {
        let cfg = SCStreamConfiguration()
        let k = 480 / max(w.frame.width, 1)
        cfg.width = Int(w.frame.width * k); cfg.height = Int(w.frame.height * k)
        cfg.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
    }

    func start(_ mode: CaptureMode, window: CGWindowID? = nil) {
        self.mode = mode
        if let window { windowID = window }
        start()
    }

    func toggle() { state == .recording ? stop() : start() }

    func start() {
        guard state == .idle else { return }
        Task {
            do { try await begin() } catch {
                lastError = error.localizedDescription
                teardown()
            }
        }
    }

    private func begin() async throws {
        lastError = nil
        cancelled = false
        if micID != nil, !(await AVCaptureDevice.requestAccess(for: .audio)) { micID = nil }
        if cameraID != nil, !(await AVCaptureDevice.requestAccess(for: .video)) { cameraID = nil }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let cfg = SCStreamConfiguration()
        let filter: SCContentFilter
        var title = lastApp
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens[0]

        switch mode {
        case .screen, .area:
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw FocoError("Tela não encontrada") }
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            scale = screen.backingScaleFactor
            let bounds = CGDisplayBounds(display.displayID)
            if mode == .area {
                var picked = reuseArea ? lastArea : nil
                reuseArea = false
                if picked == nil { picked = await AreaPicker.pick(on: screen) }
                guard let r = picked else { return }
                lastArea = r
                cfg.sourceRect = r
                region = r.offsetBy(dx: bounds.minX, dy: bounds.minY)
            } else {
                region = bounds
            }
        case .window:
            guard let w = content.windows.first(where: { $0.windowID == windowID }) else { throw FocoError("Escolha uma janela para gravar") }
            filter = SCContentFilter(desktopIndependentWindow: w)
            scale = Double(filter.pointPixelScale)
            region = w.frame
            title = (w.title?.isEmpty == false ? w.title : nil) ?? w.owningApplication?.applicationName
        }
        // como o FocuSee: no máximo 3840 px de lado (limite do H.264), mesma proporção
        let k = min(1, 3840 / (region.width * scale), 3840 / (region.height * scale))
        cfg.width = Int(region.width * scale * k / 2) * 2
        cfg.height = Int(region.height * scale * k / 2) * 2
        cfg.queueDepth = 8
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = false // o cursor é redesenhado, suavizado, na edição
        // Sem isto o ScreenCaptureKit grava cores P3 marcadas como Rec.709 e o vídeo sai desbotado.
        // Em sRGB os valores ficam corretos (a marcação continua Rec.709; o compositor relê como sRGB).
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.capturesAudio = systemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.captureMicrophone = micID != nil
        if let micID { cfg.microphoneCaptureDeviceID = micID }

        let dir = Self.newDir(title)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = try ScreenWriter(url: dir.appending(path: "raw.mov"), width: cfg.width, height: cfg.height, quality: quality,
                                 system: systemAudio, mic: micID != nil) { [weak self] start in
            Task { @MainActor in self?.t0 = start }
        }
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(w, type: .screen, sampleHandlerQueue: w.queue)
        if systemAudio { try s.addStreamOutput(w, type: .audio, sampleHandlerQueue: w.queue) }
        if micID != nil { try s.addStreamOutput(w, type: .microphone, sampleHandlerQueue: w.queue) }
        self.dir = dir; stream = s; writer = w

        if let cameraID, let dev = AVCaptureDevice(uniqueID: cameraID) ?? AVCaptureDevice.default(for: .video) {
            let cam = try CameraRecorder(device: dev)
            await cam.run()
            camera = cam
        }

        hideWindows()
        showPanels(on: screen)
        for n in stride(from: countdown, to: 0, by: -1) {
            state = .countdown(n)
            try await Task.sleep(for: .seconds(1))
            if cancelled { return }
        }
        countPanel?.orderOut(nil)

        t0 = nil; moves = []; clicks = []; keys = []; elapsed = 0
        pauses = []; pausedAt = nil; paused = false
        shapes = []; shapeKeys = [:]; currentShape = nil; tick = 0
        startTracking()
        try await s.startCapture()
        camera?.record(to: dir.appending(path: "camera.mov"))
        state = .recording
    }

    func stop() {
        guard state == .recording, let s = stream else { return }
        state = .saving
        if let p = pausedAt { pauses.append((p, Date())); pausedAt = nil }
        stopTracking()
        Task {
            try? await s.stopCapture()
            await camera?.stop()
            if let e = await writer?.finish() { lastError = e }
            finish()
        }
    }

    func cancel(then next: (() -> Void)? = nil) {
        cancelled = true
        let d = dir, s = stream, wasRecording = state == .recording
        Task {
            if wasRecording { try? await s?.stopCapture() }
            await camera?.stop()
            _ = await self.writer?.finish()
            teardown()
            if let d { try? FileManager.default.trashItem(at: d, resultingItemURL: nil) }
            next?()
        }
    }

    func togglePause() {
        guard state == .recording else { return }
        if let p = pausedAt { pauses.append((p, Date())); pausedAt = nil } else { pausedAt = Date() }
        paused = pausedAt != nil
    }

    /// Botão Excluir da barra (textos do FocuSee)
    func discard() {
        guard state == .recording, Self.confirm("Cancelar gravação?", "Esta gravação será perdida se cancelada. Deseja continuar?") else { return }
        cancel()
    }

    /// Botão Reiniciar: apaga a gravação atual e começa outra igual, com contagem
    func restart() {
        guard state == .recording,
              Self.confirm("Regravar?", "A gravação novamente irá sobrescrever o arquivo atual e criar um novo. Tem certeza de que deseja continuar?") else { return }
        reuseArea = mode == .area
        cancel { self.start() }
    }

    private static func confirm(_ title: String, _ text: String) -> Bool {
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        a.addButton(withTitle: "Continuar"); a.addButton(withTitle: "Cancelar")
        a.window.sharingType = .none
        NSApp.activate()
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Tempo pausado até `now`
    private func pausedTotal(_ now: Date) -> Double {
        pauses.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) } + (pausedAt.map { now.timeIntervalSince($0) } ?? 0)
    }

    private func finish() {
        guard let dir else { teardown(); return }
        let start = t0 ?? moves.first?.0 ?? Date()
        let r = region
        let ev = Events(
            samples: moves.compactMap { d, p, c in
                let t = d.timeIntervalSince(start)
                return t < 0 ? nil : Sample(t: t, x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height, c: c)
            },
            clicks: clicks.map { $0.timeIntervalSince(start) }.filter { $0 >= 0 },
            pointScale: scale,
            cameraOffset: camera?.startedAt.map { $0.timeIntervalSince(start) },
            cursors: shapes,
            keys: keys.compactMap { d, s, combo, caret in
                let t = d.timeIntervalSince(start)
                return t < 0 ? nil : KeyPress(t: t, s: s, combo: combo, x: caret.map { ($0.x - r.minX) / r.width }, y: caret.map { ($0.y - r.minY) / r.height })
            },
            // o ScreenWriter cria as faixas nesta ordem
            audio: (systemAudio ? ["system"] : []) + (micID != nil ? ["mic"] : []),
            pauses: pauses.map { [$0.0.timeIntervalSince(start), $0.1.timeIntervalSince(start)] })
        try? JSONEncoder().encode(ev).write(to: dir.appending(path: "events.json"))
        teardown()
        NSApp.activate()
        onFinished?(dir)
    }

    private func teardown() {
        stopTracking()
        camera?.shutdown(); camera = nil
        stream = nil; writer = nil
        panels.forEach { $0.orderOut(nil) }; panels = []; countPanel = nil
        pausedAt = nil; paused = false
        hiddenWindows.forEach { $0.orderFront(nil) }; hiddenWindows = []
        state = .idle
    }

    private func startTracking() {
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = CGEvent(source: nil)?.location else { return }
                let now = Date()
                if self.tick % 4 == 0 { self.captureCursorShape() } // 15 Hz basta para trocas de cursor
                self.tick += 1
                self.moves.append((now, p, self.currentShape))
                if let t0 = self.t0 {
                    let e = Int(now.timeIntervalSince(t0) - self.pausedTotal(now))
                    if e != self.elapsed { self.elapsed = e }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { if self?.pausedAt == nil { self?.clicks.append(Date()) } }
        }
        // teclas (para exibir atalhos e para o zoom ao digitar): exige a permissão de Acessibilidade
        if !AXIsProcessTrusted(), !Self.askedAX {
            Self.askedAX = true
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let (label, combo) = KeyLabel.make(e)
            MainActor.assumeIsolated {
                guard let self, self.pausedAt == nil else { return }
                self.keys.append((Date(), label, combo, combo ? nil : KeyLabel.caret()))
            }
        }
    }

    /// Registra o cursor atual do sistema (seta, mãozinha, texto…) e salva a imagem na primeira vez que aparece
    private func captureCursorShape() {
        guard let dir else { return }
        let c = NSCursor.currentSystem ?? NSCursor.arrow
        let size = c.image.size, hot = c.hotSpot
        guard size.width > 0 else { return }
        let key = "\(size.width)x\(size.height)@\(hot.x),\(hot.y)"
        if let i = shapeKeys[key] { currentShape = i; return }
        let art = CursorStyles.system(c)
        let file = "\(shapes.count).png"
        let folder = dir.appending(path: "cursors")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let png = NSBitmapImageRep(cgImage: art.image).representation(using: .png, properties: [:]),
              (try? png.write(to: folder.appending(path: file))) != nil else { return }
        let a = NSCursor.arrow
        let isArrow = a.image.size == size && a.hotSpot == hot
        shapes.append(CursorShape(file: file, hotX: hot.x, hotY: hot.y, width: size.width, height: size.height, isArrow: isArrow))
        shapeKeys[key] = shapes.count - 1
        currentShape = shapes.count - 1
    }

    private func stopTracking() {
        timer?.invalidate(); timer = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil; keyMonitor = nil
    }

    private func hideWindows() {
        hiddenWindows = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
        hiddenWindows.forEach { $0.orderOut(nil) }
    }

    private func showPanels(on screen: NSScreen) {
        let f = screen.visibleFrame
        panels.append(Self.panel(ControlBar(), CGRect(x: f.midX - 160, y: f.maxY - 74, width: 320, height: 60)))
        if countdown > 0 {
            let c = Self.panel(CountdownView(), CGRect(x: screen.frame.midX - 110, y: screen.frame.midY - 110, width: 220, height: 220))
            c.ignoresMouseEvents = true
            panels.append(c); countPanel = c
        }
        if let cam = camera {
            let d: CGFloat = 180
            panels.append(Self.panel(CameraBubble(session: cam.session, size: d), CGRect(x: f.maxX - d - 24, y: f.minY + 24, width: d, height: d)))
        }
    }

    private static func panel<V: View>(_ v: V, _ frame: CGRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .floating; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true; p.hidesOnDeactivate = false
        p.sharingType = .none // como no FocuSee: não aparece em prints nem em gravações
        p.contentView = NSHostingView(rootView: v)
        p.orderFrontRegardless()
        return p
    }

    /// Pasta da gravação no padrão do FocuSee: "<janela ou app> AAAA-MM-DD HH-MM-SS"
    private static func newDir(_ title: String?) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        var t = (title ?? "Tela").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 60 { t = String(t.prefix(60)) }
        return Project.baseDir.appending(path: "\(t) \(f.string(from: Date()))")
    }
}

// MARK: - Gravação da tela em arquivo (H.264 com bitrate controlado, como o gravador do FocuSee)

final class ScreenWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "foco.writer")
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let system: AVAssetWriterInput?
    private let mic: AVAssetWriterInput?
    private let onStart: (Date) -> Void
    private var started = false
    private var closed = false

    init(url: URL, width: Int, height: Int, quality: RecordQuality, system hasSystem: Bool, mic hasMic: Bool,
         onStart: @escaping (Date) -> Void) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // tabela do FocuSee: 7,5 / 14 / 22 / 45 Mbps conforme os pixels, vezes o fator da qualidade
        let px = width * height
        let base: Double = px < 409_921 ? 7_500_000 : px < 2_073_601 ? 14_000_000 : px > 3_686_400 ? 45_000_000 : 22_000_000
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: base * quality.factor, AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60,
            ],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: VideoColor.primaries, AVVideoTransferFunctionKey: VideoColor.transfer,
                                        AVVideoYCbCrMatrixKey: VideoColor.matrix],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        func audio() -> AVAssetWriterInput {
            var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000, AVEncoderBitRateKey: 192_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
            a.expectsMediaDataInRealTime = true
            return a
        }
        system = hasSystem ? audio() : nil
        mic = hasMic ? audio() : nil
        if let system { writer.add(system) }
        if let mic { writer.add(mic) }
        self.onStart = onStart
        super.init()
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !closed, sb.isValid else { return }
        switch type {
        case .screen:
            // só quadros novos (o ScreenCaptureKit também manda avisos de "tela parada" sem imagem)
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if !started {
                guard writer.startWriting() else { return }
                let pts = sb.presentationTimeStamp
                writer.startSession(atSourceTime: pts)
                started = true
                let ago = CMClockGetTime(CMClockGetHostTimeClock()).seconds - pts.seconds
                onStart(Date().addingTimeInterval(-ago))
            }
            if video.isReadyForMoreMediaData { video.append(sb) }
        case .audio:
            if started, let system, system.isReadyForMoreMediaData { system.append(sb) }
        case .microphone:
            if started, let mic, mic.isReadyForMoreMediaData { mic.append(sb) }
        @unknown default: break
        }
    }

    /// Fecha o arquivo; devolve a mensagem de erro, se houver
    func finish() async -> String? {
        let w = writer
        let ok: Bool = queue.sync {
            guard !closed else { return false }
            closed = true
            guard started else { return false }
            ([video, system, mic] as [AVAssetWriterInput?]).forEach { $0?.markAsFinished() }
            return true
        }
        guard ok else { return started ? nil : "Nenhum quadro da tela foi gravado" }
        await w.finishWriting()
        return w.status == .completed ? nil : (w.error?.localizedDescription ?? "Falha ao salvar a gravação")
    }
}

// MARK: - Câmera

final class CameraRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private(set) var startedAt: Date?
    private var done: CheckedContinuation<Void, Never>?

    init(device: AVCaptureDevice) throws {
        super.init()
        session.beginConfiguration()
        session.sessionPreset = .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw FocoError("Câmera indisponível") }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
    }

    func run() async { await Task.detached { [session] in session.startRunning() }.value }
    func record(to url: URL) { output.startRecording(to: url, recordingDelegate: self) }
    func stop() async {
        guard output.isRecording else { return }
        await withCheckedContinuation { c in done = c; output.stopRecording() }
    }
    func shutdown() { session.stopRunning() }

    func fileOutput(_ o: AVCaptureFileOutput, didStartRecordingTo u: URL, from c: [AVCaptureConnection]) { startedAt = Date() }
    func fileOutput(_ o: AVCaptureFileOutput, didFinishRecordingTo u: URL, from c: [AVCaptureConnection], error: Error?) {
        done?.resume(); done = nil
    }
}

struct CameraBubble: NSViewRepresentable {
    let session: AVCaptureSession
    let size: CGFloat
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let l = AVCaptureVideoPreviewLayer(session: session)
        l.videoGravity = .resizeAspectFill
        l.cornerRadius = size / 2; l.masksToBounds = true
        l.borderWidth = 3; l.borderColor = NSColor.white.cgColor
        v.layer = l; v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

struct ControlBar: View {
    @ObservedObject var rec = Recorder.shared
    var body: some View {
        HStack(spacing: 4) {
            switch rec.state {
            case .countdown(let n):
                Text("Gravando em \(n)…").font(.headline).padding(.horizontal, 6)
                Button("Cancelar") { rec.cancel() }.buttonStyle(.borderless)
            case .saving:
                ProgressView().controlSize(.small)
                Text("Salvando…")
            default:
                BarButton(icon: "trash", tip: "Excluir") { rec.discard() }
                BarButton(icon: "arrow.counterclockwise", tip: "Reiniciar") { rec.restart() }
                BarButton(icon: rec.paused ? "play.fill" : "pause.fill", tip: rec.paused ? "Continuar (⌥⇧P)" : "Pausar (⌥⇧P)") { rec.togglePause() }
                Text(clock(Double(rec.elapsed))).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(rec.paused ? .secondary : .primary)
                    .frame(minWidth: 58)
                Button { rec.stop() } label: {
                    RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 12, height: 12)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(LinearGradient(colors: [Color(red: 0.25, green: 0.45, blue: 1), Color(red: 0.65, green: 0.35, blue: 1)],
                                                                 startPoint: .leading, endPoint: .trailing)))
                }
                .buttonStyle(.plain).help("Terminar gravação (⌥⇧R)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15)))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BarButton: View {
    let icon: String, tip: String, action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 15)).frame(width: 34, height: 34).contentShape(Rectangle()) }
            .buttonStyle(.borderless).help(tip)
    }
}

/// Contagem regressiva no centro da tela (3, 2, 1…)
struct CountdownView: View {
    @ObservedObject var rec = Recorder.shared
    var body: some View {
        if case .countdown(let n) = rec.state {
            Text("\(n)").font(.system(size: 120, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.easeOut(duration: 0.3), value: n)
                .frame(width: 200, height: 200)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 44))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Teclas

enum KeyLabel {
    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Espaço", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "esc", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Rótulo no estilo do macOS ("⌃⌥⇧⌘K") e se é uma combinação (tem ⌘, ⌃ ou ⌥)
    static func make(_ e: NSEvent) -> (String, Bool) {
        let f = e.modifierFlags
        var m = ""
        if f.contains(.control) { m += "⌃" }
        if f.contains(.option) { m += "⌥" }
        if f.contains(.shift) { m += "⇧" }
        if f.contains(.command) { m += "⌘" }
        let combo = f.contains(.command) || f.contains(.control) || f.contains(.option)
        let key = special[Int(e.keyCode)] ?? (e.charactersIgnoringModifiers ?? "").uppercased()
        // texto comum: a letra como foi digitada (com ⇧ já aplicado), sem o símbolo ⇧
        if !combo, special[Int(e.keyCode)] == nil { return (e.characters ?? key, false) }
        return (m + key, combo)
    }

    /// Posição do cursor de texto no app em foco (coordenadas globais, origem no topo), via Acessibilidade
    static func caret() -> CGPoint? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        var el: CFTypeRef?, range: CFTypeRef?, bounds: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &el) == .success, let el,
              AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let range,
              AXUIElementCopyParameterizedAttributeValue(el as! AXUIElement, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &r), r.origin != .zero || r.size != .zero else { return nil }
        return CGPoint(x: r.midX, y: r.midY)
    }
}

// MARK: - Seleção de área

@MainActor
enum AreaPicker {
    private static var window: NSWindow?

    /// Retorna o retângulo em pontos, relativo à tela, com origem no topo
    static func pick(on screen: NSScreen) async -> CGRect? {
        await withCheckedContinuation { cont in
            let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear
            w.contentView = AreaView { r in
                w.orderOut(nil); window = nil
                cont.resume(returning: r.map { CGRect(x: $0.minX, y: screen.frame.height - $0.maxY, width: $0.width, height: $0.height) })
            }
            window = w
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(w.contentView)
        }
    }
}

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class AreaView: NSView {
    private var start: CGPoint?
    private var rect: CGRect?
    private var done: ((CGRect?) -> Void)?

    init(done: @escaping (CGRect?) -> Void) { self.done = done; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private func finish(_ r: CGRect?) { done?(r); done = nil }

    override func draw(_ dirty: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 18, weight: .semibold)]
        if let rect {
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSColor.white.setStroke()
            let p = NSBezierPath(rect: rect); p.lineWidth = 2; p.stroke()
            ("\(Int(rect.width)) × \(Int(rect.height))" as NSString).draw(at: CGPoint(x: rect.minX, y: rect.maxY + 6), withAttributes: attrs)
        } else {
            let s = "Arraste para selecionar a área · Esc cancela" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: bounds.midX - sz.width / 2, y: bounds.midY), withAttributes: attrs)
        }
    }

    override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil) }
    override func mouseDragged(with e: NSEvent) {
        guard let start else { return }
        let p = convert(e.locationInWindow, from: nil)
        rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y)).integral
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        if let rect, rect.width > 40, rect.height > 40 { finish(rect) }
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { finish(nil) }
    }
}

// MARK: - Atalho global ⌥⇧R (Carbon não exige permissão de acessibilidade)

enum HotKey {
    nonisolated(unsafe) static var actions: [UInt32: () -> Void] = [:]

    /// ⌥⇧ + tecla
    static func register(_ key: Int, _ action: @escaping () -> Void) {
        if actions.isEmpty {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
                var id = EventHotKeyID()
                GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                HotKey.actions[id.id]?()
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(optionKey | shiftKey), EventHotKeyID(signature: 0x4643_4F31, id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }
}
