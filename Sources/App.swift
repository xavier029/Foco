import SwiftUI
import AVFoundation
import ScreenCaptureKit
import Carbon.HIToolbox

@main
struct FocoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Foco", id: "home") { HomeView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
        Window("Histórico do Arquivo", id: "history") { HistoryView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 960, height: 640)
        Window("Escolha a janela", id: "picker") { WindowPicker() }
            .windowResizability(.contentSize)
        WindowGroup("Editor", for: URL.self) { $url in
            if let url { EditorView(dir: url) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        MenuBarExtra { MenuContent() } label: { MenuLabel() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        HotKey.register(kVK_ANSI_R) { Task { @MainActor in Recorder.shared.toggle() } }
        HotKey.register(kVK_ANSI_P) { Task { @MainActor in Recorder.shared.togglePause() } }
        let a = CommandLine.arguments

        // Teste de cor: grava 4 s da tela (sem áudio/câmera) e imprime a pasta
        if a.contains("--rectest") {
            Task { @MainActor in
                let r = Recorder.shared
                let saved = (r.micID, r.cameraID, r.systemAudio)
                r.micID = nil; r.cameraID = nil; r.systemAudio = false
                // --audio: grava também o áudio do sistema e, se já houver permissão, o microfone
                if a.contains("--audio") {
                    r.systemAudio = true
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { r.micID = AVCaptureDevice.default(for: .audio)?.uniqueID }
                    print("microfone:", r.micID ?? "sem permissão")
                }
                r.onFinished = { url in
                    (r.micID, r.cameraID, r.systemAudio) = saved
                    print(url.path); exit(0)
                }
                r.start(.screen)
                try? await Task.sleep(for: .seconds(7)) // 3 s de contagem + 4 s gravando
                if r.state != .recording { print("erro:", r.lastError ?? "não começou a gravar"); exit(1) }
                r.stop()
            }
        }

        // Exportação sem interface (testes): Foco --export <pasta da gravação>
        if let i = a.firstIndex(of: "--export"), i + 1 < a.count {
            Task { @MainActor in
                let p = Project(dir: URL(fileURLWithPath: a[i + 1]))
                do {
                    let ev = try p.loadEvents()
                    let s = p.loadSettings() ?? Settings.initial(for: p, events: ev)
                    let inp = RenderInputs(project: p, events: ev, settings: s, style: CursorStyles.art(s.cursorStyle),
                                           shapes: CursorStyles.recorded(ev, dir: p.dir))
                    var o = ExportOptions(); o.shortSide = 1080; o.folder = p.dir.path
                    if a.contains("--gif") { o.format = .gif; o.fps = 15; o.shortSide = 480 }
                    print(try await exportVideo(inp, options: o, name: "Foco") { _ in }.path)
                } catch { print("erro:", error) }
                exit(0)
            }
        }
    }
}

struct MenuLabel: View {
    @ObservedObject var rec = Recorder.shared
    var body: some View { Image(systemName: rec.state == .recording ? "record.circle.fill" : "record.circle") }
}

struct MenuContent: View {
    @ObservedObject var rec = Recorder.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if rec.state == .recording {
            Button(rec.paused ? "Continuar gravação" : "Pausar gravação") { rec.togglePause() }
            Button("Terminar gravação") { rec.stop() }
        } else {
            Button("Gravar (\(rec.mode.rawValue))") { rec.start() }.disabled(rec.state != .idle)
        }
        Button("Abrir Foco") { openWindow(id: "home"); NSApp.activate() }
        Divider()
        Button("Sair") { NSApp.terminate(nil) }
            .onAppear { rec.onFinished = rec.onFinished ?? { openWindow(value: $0) } }
    }
}


// MARK: - Tela inicial (estilo FocuSee)

struct HomeView: View {
    @ObservedObject var rec = Recorder.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    if !rec.canCapture { PermissionBanner() }
                    Text("Selecione o modo de gravação").font(.title3).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        ModeCard(title: "Tela cheia", art: .screen) { rec.start(.screen) }
                        ModeCard(title: "Personalizado", art: .area) { rec.start(.area) }
                        ModeCard(title: "Janela", art: .window) { openWindow(id: "picker") }
                    }
                    .disabled(rec.state != .idle)
                    if let e = rec.lastError { Text(e).font(.callout).foregroundStyle(.red) }
                }
                .padding(.horizontal, 28).padding(.bottom, 28)
                Divider().frame(height: 260)
                devices.frame(width: 300).padding(.horizontal, 24).padding(.bottom, 28)
            }
        }
        .frame(width: 1080)
        .ignoresSafeArea(edges: .top)
        .background(Color(red: 0.10, green: 0.10, blue: 0.12))
        .preferredColorScheme(.dark)
        .task {
            await rec.refreshSources()
            // Foco --open <pasta da gravação> abre direto no editor
            let a = CommandLine.arguments
            if let i = a.firstIndex(of: "--open"), i + 1 < a.count { openWindow(value: URL(fileURLWithPath: a[i + 1])) }
            if a.contains("--pick") { openWindow(id: "picker") }
        }
        .onAppear { rec.onFinished = { openWindow(value: $0) } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
            Text("Foco").font(.title2.bold())
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .overlay(alignment: .trailing) {
            Button { openWindow(id: "history") } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 17))
            }
            .buttonStyle(.borderless)
            .help("Gravações recentes")
            .padding(.trailing, 22)
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Equipamentos").font(.title3).foregroundStyle(.secondary)
            DeviceRow(icon: rec.cameraID == nil ? "video.slash" : "video.fill") {
                Picker("Câmera", selection: $rec.cameraID) {
                    Text("Nenhuma câmera").tag(String?.none)
                    ForEach(rec.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
            }
            DeviceRow(icon: rec.micID == nil ? "mic.slash" : "mic.fill") {
                Picker("Microfone", selection: $rec.micID) {
                    Text("Nenhum microfone").tag(String?.none)
                    ForEach(rec.mics, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
            }
            DeviceRow(icon: rec.systemAudio ? "speaker.wave.2.fill" : "speaker.slash") {
                Picker("Áudio do sistema", selection: $rec.systemAudio) {
                    Text("Áudio do sistema").tag(true)
                    Text("Sem áudio do sistema").tag(false)
                }
            }
            DeviceRow(icon: "timer") {
                Picker("Contagem regressiva", selection: $rec.countdown) {
                    Text("Sem contagem regressiva").tag(0)
                    Text("Contagem de 3s").tag(3)
                    Text("Contagem de 5s").tag(5)
                }
            }
            DeviceRow(icon: "sparkles.tv") {
                Picker("Qualidade da Gravação", selection: $rec.quality) {
                    ForEach(RecordQuality.allCases) { Text("Qualidade: \($0.rawValue)").tag($0) }
                }
            }
            .help("Qualidade mais alta produz um vídeo mais nítido, mas aumenta o tamanho do arquivo.")
            Divider().padding(.vertical, 4)
            Text("⌥⇧R inicia e termina a gravação · ⌥⇧P pausa e continua").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DeviceRow<Content: View>: View {
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 17))
                .frame(width: 46, height: 40)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            content.labelsHidden().controlSize(.large).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum CardArt { case screen, area, window }

struct ModeCard: View {
    let title: String
    let art: CardArt
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 18) {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.30, green: 0.22, blue: 0.90), Color(red: 0.10, green: 0.08, blue: 0.40),
                                            Color(red: 0.30, green: 0.45, blue: 0.98)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Wave().fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    switch art {
                    case .screen:
                        EmptyView()
                    case .area:
                        Rectangle().stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .padding(.horizontal, 52).padding(.vertical, 24)
                    case .window:
                        RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.7))
                            .overlay(alignment: .topLeading) {
                                HStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in Circle().fill(.white).frame(width: 6, height: 6) } }
                                    .padding(8)
                            }
                            .padding(.horizontal, 48).padding(.vertical, 20)
                    }
                }
                .frame(height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(title).font(.title3.bold())
            }
            .padding(18)
            .frame(width: 226)
            .background(Color.white.opacity(hover ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(hover ? Color.accentColor : .clear, lineWidth: 2))
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct Wave: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: r.height * 0.9))
        p.addCurve(to: CGPoint(x: r.width, y: r.height * 0.1),
                   control1: CGPoint(x: r.width * 0.5, y: r.height * 1.0), control2: CGPoint(x: r.width * 0.55, y: r.height * 0.05))
        p.addLine(to: CGPoint(x: r.width, y: r.height))
        p.addLine(to: CGPoint(x: 0, y: r.height))
        p.closeSubpath()
        return p
    }
}

// MARK: - Seletor de janela

struct PermissionBanner: View {
    @ObservedObject var rec = Recorder.shared
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("O Foco precisa de permissão de **Gravação de Tela**. Depois de permitir, feche e abra o Foco de novo.")
                .font(.callout)
            Spacer()
            Button("Permitir") { rec.requestCapturePermission() }
        }
        .padding(12)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WindowPicker: View {
    @ObservedObject var rec = Recorder.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var thumbs: [CGWindowID: CGImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Escolha a janela para gravar").font(.title2.bold())
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("Atualizar")
                Button("Cancelar") { dismissWindow() }.keyboardShortcut(.cancelAction)
            }
            if !rec.canCapture {
                PermissionBanner()
            } else if rec.windows.isEmpty {
                ContentUnavailableView("Nenhuma janela encontrada", systemImage: "macwindow",
                                       description: Text("Abra o app que você quer gravar e clique em atualizar."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                        ForEach(rec.windows, id: \.windowID) { w in
                            WindowTile(window: w, thumb: thumbs[w.windowID]) {
                                dismissWindow()
                                rec.start(.window, window: w.windowID)
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 840, height: 560, alignment: .top)
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private func load() async {
        await rec.refreshSources()
        for w in rec.windows where thumbs[w.windowID] == nil {
            thumbs[w.windowID] = await rec.thumbnail(w)
        }
    }
}

struct WindowTile: View {
    let window: SCWindow
    let thumb: CGImage?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06))
                    if let thumb { Image(decorative: thumb, scale: 1).resizable().scaledToFit().padding(8) } else { ProgressView() }
                }
                .frame(height: 130)
                HStack(spacing: 8) {
                    if let pid = window.owningApplication?.processID, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(window.owningApplication?.applicationName ?? "").font(.callout.bold()).lineLimit(1)
                        Text(window.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(10)
            .background(hover ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(hover ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Histórico do arquivo (como no FocuSee)

struct HistoryView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var rec = Recorder.shared
    @State private var tab = 0
    @State private var query = ""
    @State private var projects: [URL] = []
    @State private var checked: Set<URL> = []
    @State private var refresh = 0
    @State private var pendingDelete: [URL] = [] // aguardando confirmação
    @State private var renaming: URL?            // projeto ou vídeo exportado sendo renomeado
    @State private var newName = ""
    @State private var renameError: String?

    private var filtered: [URL] {
        query.isEmpty ? projects : projects.filter { Project(dir: $0).name.localizedCaseInsensitiveContains(query) }
    }
    private var exports: [(file: URL, project: Project)] {
        projects.flatMap { u in Project(dir: u).meta.exports.map { (URL(fileURLWithPath: $0), Project(dir: u)) } }
            .filter { FileManager.default.fileExists(atPath: $0.file.path) }
            .filter { query.isEmpty || $0.file.lastPathComponent.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Histórico do Arquivo").font(.title.bold()).frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                ForEach(Array(["Histórico do Projeto", "Histórico de Exportação"].enumerated()), id: \.offset) { i, t in
                    Tile(selected: tab == i, radius: 9, action: { tab = i; checked = [] }) { Text(t).padding(.horizontal, 14).padding(.vertical, 8) }
                        .fixedSize()
                }
                Spacer()
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.text2)
                    TextField("Pesquisar", text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 12).frame(width: 320, height: 38)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
            }
            Divider()
            if !checked.isEmpty {
                let all = tab == 0 ? filtered : exports.map(\.file)
                HStack(spacing: 14) {
                    Text("\(checked.count) selecionado(s)")
                    Spacer()
                    Button(checked.count == all.count ? "Desmarcar tudo" : "Selecionar tudo") {
                        checked = checked.count == all.count ? [] : Set(all)
                    }
                    Button("Excluir", role: .destructive) { pendingDelete = Array(checked) }
                }
                .padding(10).background(Theme.field, in: RoundedRectangle(cornerRadius: 9))
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    if tab == 0 {
                        ForEach(filtered, id: \.self) { url in projectRow(Project(dir: url)) }
                        if filtered.isEmpty { empty("Nenhum projeto ainda") }
                    } else {
                        ForEach(exports, id: \.file) { e in exportRow(e.file, from: e.project) }
                        if exports.isEmpty { empty("Nenhum vídeo exportado ainda") }
                    }
                }
                .id(refresh)
            }
        }
        .padding(28)
        .frame(minWidth: 900, minHeight: 600, alignment: .top)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .onAppear { reload() }
        .onChange(of: rec.state) { if rec.state == .idle { reload() } }
        .alert(pendingDelete.count > 1 ? "Tem certeza de que deseja excluir \(pendingDelete.count) arquivos selecionados?"
                                        : "Tem certeza de que deseja excluir este item?",
               isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            Button("Excluir agora", role: .destructive) {
                // exclusão definitiva: o arquivo sai do computador (não vai para o Lixo)
                for u in pendingDelete { try? FileManager.default.removeItem(at: u) }
                checked.subtract(pendingDelete); pendingDelete = []; reload()
            }
            Button("Cancelar", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("Uma vez excluído, o arquivo não poderá ser recuperado. Prossiga com cautela.")
        }
        .alert("Renomear", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("OK") { if let u = renaming { rename(u, to: newName) } }
            Button("Cancelar", role: .cancel) {}
        }
        .alert(renameError ?? "", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("OK") {}
        }
    }

    private func startRename(_ u: URL, current: String) { newName = current; renaming = u }

    /// Projetos: o nome fica no meta.json. Vídeos exportados: o arquivo muda de nome (mesma extensão).
    private func rename(_ u: URL, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            renameError = "Formato de nome de arquivo inválido. Insira um nome válido."; return
        }
        if projects.contains(u) {
            guard !projects.contains(where: { $0 != u && Project(dir: $0).name == name }) else {
                renameError = "O nome do arquivo já existe. Use outro nome."; return
            }
            var m = Project(dir: u).meta; m.title = name; Project(dir: u).meta = m
        } else {
            let dest = u.deletingLastPathComponent().appending(path: name).appendingPathExtension(u.pathExtension)
            guard dest != u else { return }
            guard !FileManager.default.fileExists(atPath: dest.path) else { renameError = "O nome do arquivo já existe. Use outro nome."; return }
            do { try FileManager.default.moveItem(at: u, to: dest) } catch { renameError = error.localizedDescription; return }
            for d in projects {
                var m = Project(dir: d).meta
                if let k = m.exports.firstIndex(of: u.path) { m.exports[k] = dest.path; Project(dir: d).meta = m }
            }
        }
        reload()
    }

    private func reload() { projects = Project.all(); refresh += 1 }

    private func empty(_ s: String) -> some View {
        ContentUnavailableView(s, systemImage: "film.stack").padding(.top, 80)
    }

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "pt_BR"); f.unitsStyle = .full; return f
    }()
    private func ago(_ d: Date?) -> String { d.map { Self.rel.localizedString(for: $0, relativeTo: Date()) } ?? "nunca" }

    private func check(_ u: URL) -> Binding<Bool> {
        Binding(get: { checked.contains(u) }, set: { if $0 { checked.insert(u) } else { checked.remove(u) } })
    }

    private func projectRow(_ p: Project) -> some View {
        HistoryRow(thumbSource: p.raw, check: check(p.dir), title: p.name,
                   detail: "Gravar projeto | Última abertura: \(ago(p.meta.lastOpened)) | Criado em: \(ago(p.created))",
                   open: { openWindow(value: p.dir) }) {
            Button { openWindow(value: p.dir) } label: { Image(systemName: "pencil") }.help("Editar")
            Button { startRename(p.dir, current: p.name) } label: { Image(systemName: "character.cursor.ibeam") }.help("Renomear")
            Button { NSWorkspace.shared.activateFileViewerSelecting([p.dir]) } label: { Image(systemName: "folder") }.help("Mostrar no Finder")
            Button { pendingDelete = [p.dir] } label: { Image(systemName: "trash") }.help("Excluir do computador")
        }
    }

    private func exportRow(_ f: URL, from p: Project) -> some View {
        let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        let date = try? f.resourceValues(forKeys: [.creationDateKey]).creationDate
        return HistoryRow(thumbSource: f, check: check(f), title: f.lastPathComponent,
                          detail: "Exportado de \(p.name) | \(ago(date)) | \(size)",
                          open: { NSWorkspace.shared.open(f) }) {
            Button { NSWorkspace.shared.open(f) } label: { Image(systemName: "play.fill") }.help("Abrir")
            Button { startRename(f, current: f.deletingPathExtension().lastPathComponent) } label: { Image(systemName: "character.cursor.ibeam") }.help("Renomear")
            Button { NSWorkspace.shared.activateFileViewerSelecting([f]) } label: { Image(systemName: "folder") }.help("Mostrar no Finder")
            Button { pendingDelete = [f] } label: { Image(systemName: "trash") }.help("Excluir do computador")
        }
    }
}

struct HistoryRow<Actions: View>: View {
    let thumbSource: URL
    @Binding var check: Bool
    let title: String
    let detail: String
    let open: () -> Void
    @ViewBuilder let actions: Actions
    @State private var thumb: CGImage?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 18) {
            Toggle("", isOn: $check).toggleStyle(.checkbox).labelsHidden()
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.field)
                if let thumb { Image(decorative: thumb, scale: 1).resizable().scaledToFill() }
            }
            .frame(width: 150, height: 86)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture(perform: open)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3).lineLimit(1)
                Text(detail).font(.callout).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 18) { actions }
                .buttonStyle(.plain).font(.system(size: 17)).foregroundStyle(Theme.text2)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(hover ? Theme.field : .clear, in: RoundedRectangle(cornerRadius: 10))
        .onHover { hover = $0 }
        .task { thumb = await Self.thumbnail(thumbSource) }
    }

    static func thumbnail(_ u: URL) async -> CGImage? {
        if u.pathExtension.lowercased() == "gif" {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary)
        }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: u))
        g.maximumSize = CGSize(width: 320, height: 320)
        return try? await g.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    }
}
