import IAtrackerBarCore
import CoreServices
import Foundation
import os

/// Observa os logs locais (Claude Code, Gemini CLI) com FSEvents — sem polling de arquivos.
/// Toda leitura acontece numa fila própria; `onChange` é chamado na main thread.
final class LogWatcher: @unchecked Sendable {
    /// Intervalo para fechar sessões de log cujo último evento passou de 2 min.
    static let sweepInterval: TimeInterval = 30

    var onChange: @MainActor () -> Void = {}

    private let ingestors: [LogIngestor]
    private let queue = DispatchQueue(label: "IAtrackerBar.LogWatcher", qos: .utility)
    private let logger = Logger(subsystem: "IAtrackerBar", category: "LogWatcher")
    private var stream: FSEventStreamRef?
    private var sweepTimer: DispatchSourceTimer?
    private var paused: Bool

    init(database: AppDatabase, paused: Bool) {
        self.ingestors = [ClaudeCodeIngestor(database: database), GeminiCLIIngestor(database: database)]
        self.paused = paused
    }

    func start() {
        queue.async { [self] in
            if !paused {
                // Primeira leitura: importa o histórico recente e retoma de onde parou.
                run { try $0.ingest(nil, now: .now) }
                startStream()
            }
            startSweep()
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [self] in
            guard self.paused != paused else { return }
            self.paused = paused
            if paused {
                stopStream()
            }
            // Ao pausar fecha as sessões abertas; ao retomar ignora o que foi escrito na pausa.
            run { ingestor in
                try ingestor.fastForward(now: .now)
                return true
            }
            if !paused { startStream() }
        }
    }

    // MARK: FSEvents

    private func startStream() {
        guard stream == nil else { return }
        // Observa a pasta mais próxima que existe, para notar quando o CLI criar as suas.
        let paths = Array(Set(ingestors.map { Self.nearestExisting($0.root).path }))
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LogWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            watcher.handle(paths)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags
        ) else {
            logger.error("Não foi possível observar os logs")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Chamado na `queue` pelo FSEvents.
    private func handle(_ paths: [String]) {
        guard !paused else { return }
        run { ingestor in
            let root = ingestor.root.path
            let files = paths.filter { $0.hasPrefix(root) }.map { URL(fileURLWithPath: $0) }
            return files.isEmpty ? false : try ingestor.ingest(files, now: .now)
        }
    }

    private func startSweep() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.sweepInterval, repeating: Self.sweepInterval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, !self.paused else { return }
            self.run { try $0.sweep(now: .now) }
        }
        timer.resume()
        sweepTimer = timer
    }

    /// Roda em cada ingestor; erros são registrados e nunca derrubam o app.
    private func run(_ work: (LogIngestor) throws -> Bool) {
        var changed = false
        for ingestor in ingestors {
            do {
                changed = try work(ingestor) || changed
            } catch {
                logger.error("Falha ao ler logs: \(error.localizedDescription, privacy: .public)")
            }
        }
        if changed {
            DispatchQueue.main.async { [onChange] in
                MainActor.assumeIsolated { onChange() }
            }
        }
    }

    private static func nearestExisting(_ url: URL) -> URL {
        var current = url
        while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
            current.deleteLastPathComponent()
        }
        return current
    }
}
