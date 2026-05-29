import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

// MARK: - WebPlaybackCaptureRecorder

/// Records the audio that WebKit is already decoding and playing.
///
/// This uses the same Core Audio process-tap plumbing as the equalizer,
/// but instead of filtering the stream it tees the PCM into a temporary
/// CAF file that is later converted into MP3 for offline storage.
final class WebPlaybackCaptureRecorder: @unchecked Sendable {
    enum RecorderError: Error {
        case noAudioSource
        case tapCreation(OSStatus)
        case aggregateDeviceCreation
        case fileCreation(Error)
        case engineStart(OSStatus)
        case audioFormatUnavailable
        case timedOut
        case cancelled
    }

    private struct PCMChunk {
        let left: Data
        let right: Data?
        let frameCount: Int
    }

    private let logger = DiagnosticsLogger.player
    private let fileManager: FileManager
    private let rootURL: URL

    private let tapHelper = ProcessTapHelper()
    private var ioProcID: AudioDeviceIOProcID?
    private var writerTask: Task<Void, Never>?
    private var outputFile: AVAudioFile?
    private var outputURL: URL?
    private var processingFormat: AVAudioFormat?

    private var pendingChunks: [PCMChunk] = []
    private let pendingChunksLock = NSLock()
    private var isRecording = false
    private var hasReceivedAudio = false

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? Self.defaultRootURL()
    }

    deinit {
        self.stop()
    }

    /// Records one song by driving playback through the existing WebView and
    /// capturing the decoded PCM from the Core Audio process tap.
    @MainActor
    static func capture(
        song: Song,
        using playerService: PlayerService,
        fileManager: FileManager = .default,
        rootURL: URL? = nil
    ) async throws -> URL {
        let recorder = WebPlaybackCaptureRecorder(fileManager: fileManager, rootURL: rootURL)
        do {
            await playerService.play(
                song: song,
                webLoadStrategy: .forceFullPageWhenSameVideoId
            )

            let tempURL = try await recorder.startWhenAudioSourceAppears(timeout: .seconds(10))

            try await recorder.waitForPlaybackStart(
                videoId: song.videoId,
                playerService: playerService
            )
            try await recorder.waitForPlaybackEnd(
                videoId: song.videoId,
                playerService: playerService
            )

            guard recorder.didReceiveAudio else {
                throw RecorderError.noAudioSource
            }
            recorder.stop()
            await recorder.finish()
            return tempURL
        } catch {
            recorder.stop()
            await recorder.finish()
            throw error
        }
    }

    private func startWhenAudioSourceAppears(timeout: Duration) async throws -> URL {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var lastFailure: RecorderError?

        while ContinuousClock.now < deadline {
            do {
                return try self.start()
            } catch let error as RecorderError {
                lastFailure = error
                if case .noAudioSource = error {
                    try await Task.sleep(for: .milliseconds(150))
                    continue
                }
                throw error
            } catch {
                throw error
            }
        }

        throw lastFailure ?? RecorderError.noAudioSource
    }

    private var didReceiveAudio: Bool {
        self.pendingChunksLock.lock()
        defer { self.pendingChunksLock.unlock() }
        return self.hasReceivedAudio
    }

    func start() throws -> URL {
        guard !self.isRecording else {
            return self.outputURL ?? Self.tempCaptureURL(in: self.rootURL)
        }

        guard #available(macOS 14.2, *) else {
            throw RecorderError.noAudioSource
        }

        let processTapResult = self.tapHelper.start()
        switch processTapResult {
        case .success:
            break
        case .failure(.noAudioSource):
            throw RecorderError.noAudioSource
        case let .failure(.tapCreation(status)):
            throw RecorderError.tapCreation(status)
        case .failure(.permissionDenied):
            throw RecorderError.noAudioSource
        case .failure(.aggregateDeviceCreation):
            throw RecorderError.aggregateDeviceCreation
        case .failure(.unsupportedOS):
            throw RecorderError.noAudioSource
        }

        guard let streamDescription = self.tapHelper.tapStreamDescription else {
            self.tapHelper.stop()
            throw RecorderError.audioFormatUnavailable
        }
        var mutableStreamDescription = streamDescription
        guard let processingFormat = AVAudioFormat(streamDescription: &mutableStreamDescription) else {
            self.tapHelper.stop()
            throw RecorderError.audioFormatUnavailable
        }

        self.processingFormat = processingFormat
        let outputURL = Self.tempCaptureURL(in: self.rootURL)
        try self.fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            self.outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: processingFormat.settings
            )
        } catch {
            self.tapHelper.stop()
            throw RecorderError.fileCreation(error)
        }

        self.outputURL = outputURL
        self.isRecording = true
        self.writerTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.flushLoop()
        }

        let aggregateID = self.tapHelper.aggregateDeviceID
        let selfRef = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(
            aggregateID,
            Self.ioProcCallback,
            selfRef,
            &procID
        )
        guard createStatus == noErr, let procID else {
            self.stop()
            throw RecorderError.engineStart(createStatus)
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            self.stop()
            throw RecorderError.engineStart(startStatus)
        }

        return outputURL
    }

    func stop() {
        self.isRecording = false

        if let procID = self.ioProcID {
            let aggregateID = self.tapHelper.aggregateDeviceID
            if aggregateID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            self.ioProcID = nil
        }

        self.tapHelper.stop()
    }

    func finish() async {
        await self.writerTask?.value
        self.writerTask = nil
        self.outputFile = nil
        self.processingFormat = nil
    }

    @MainActor
    private func waitForPlaybackStart(videoId: String, playerService: PlayerService) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { throw RecorderError.cancelled }
            if playerService.currentTrack?.videoId == videoId, playerService.isPlaying {
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw RecorderError.timedOut
    }

    @MainActor
    private func waitForPlaybackEnd(videoId: String, playerService: PlayerService) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(900))
        var sawStart = false
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { throw RecorderError.cancelled }
            let currentVideoId = playerService.currentTrack?.videoId
            if currentVideoId == videoId, playerService.isPlaying {
                sawStart = true
            } else if sawStart {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw RecorderError.timedOut
    }

    private func appendCapturedAudio(inputBuffers: UnsafePointer<AudioBufferList>, frameCount: UInt32) {
        guard self.isRecording else { return }

        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBuffers))
        guard !list.isEmpty else { return }

        let first = list[0]
        guard let leftDataPtr = first.mData, first.mDataByteSize > 0 else { return }

        let frameBytes = Int(frameCount) * MemoryLayout<Float>.size
        let leftData = Data(bytes: leftDataPtr, count: min(Int(first.mDataByteSize), frameBytes))
        let rightData: Data? = if list.count > 1, let rightPtr = list[1].mData, list[1].mDataByteSize > 0 {
            Data(bytes: rightPtr, count: min(Int(list[1].mDataByteSize), frameBytes))
        } else {
            nil
        }

        self.pendingChunksLock.lock()
        self.hasReceivedAudio = true
        self.pendingChunks.append(PCMChunk(left: leftData, right: rightData, frameCount: Int(frameCount)))
        self.pendingChunksLock.unlock()
    }

    private func flushLoop() async {
        while !Task.isCancelled {
            let chunks: [PCMChunk] = {
                self.pendingChunksLock.lock()
                defer { self.pendingChunksLock.unlock() }
                guard !self.pendingChunks.isEmpty else { return [] }
                let next = self.pendingChunks
                self.pendingChunks.removeAll(keepingCapacity: true)
                return next
            }()

            if chunks.isEmpty {
                if !self.isRecording {
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }

            guard let outputFile = self.outputFile,
                  let format = self.processingFormat
            else { return }

            for chunk in chunks {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(chunk.frameCount)
                ) else {
                    continue
                }

                buffer.frameLength = AVAudioFrameCount(chunk.frameCount)
                let frameCount = Int(buffer.frameLength)
                if let channelData = buffer.floatChannelData {
                    chunk.left.withUnsafeBytes { rawBuffer in
                        guard let src = rawBuffer.bindMemory(to: Float.self).baseAddress else { return }
                        channelData[0].update(from: src, count: frameCount)
                    }

                    if let right = chunk.right {
                        if buffer.format.channelCount > 1 {
                            right.withUnsafeBytes { rawBuffer in
                                guard let src = rawBuffer.bindMemory(to: Float.self).baseAddress else { return }
                                channelData[1].update(from: src, count: frameCount)
                            }
                        }
                    } else if buffer.format.channelCount > 1 {
                        channelData[1].update(from: channelData[0], count: frameCount)
                    }
                }

                try? outputFile.write(from: buffer)
            }
        }
    }

    private static func tempCaptureURL(in rootURL: URL) -> URL {
        let captureFolder = rootURL.appendingPathComponent("captures", isDirectory: true)
        let fileName = UUID().uuidString + ".caf"
        return captureFolder.appendingPathComponent(fileName)
    }

    private static func defaultRootURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return appSupport.appendingPathComponent("Kaset", isDirectory: true).appendingPathComponent(
            OfflineStorageManager.Constants.folderName,
            isDirectory: true
        )
    }

    private static let ioProcCallback: AudioDeviceIOProc = { _, _, inInputData, _, outOutputData, _, inClientData in
        guard let inClientData else { return kAudioUnitErr_NoConnection }
        let recorder = Unmanaged<WebPlaybackCaptureRecorder>
            .fromOpaque(inClientData)
            .takeUnretainedValue()
        let outList = UnsafeMutableAudioBufferListPointer(outOutputData)
        let frames = outList.isEmpty ? 0 : outList[0].mDataByteSize / 4
        if frames > 0 {
            let mutableInput = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let channelCount = min(mutableInput.count, outList.count)
            for index in 0 ..< channelCount {
                guard let src = mutableInput[index].mData,
                      let dst = outList[index].mData
                else { continue }
                memcpy(dst, src, Int(mutableInput[index].mDataByteSize))
            }
            recorder.appendCapturedAudio(inputBuffers: inInputData, frameCount: frames)
        }
        return noErr
    }
}

// MARK: - WebPlaybackCaptureRecorder.RecorderError + LocalizedError

extension WebPlaybackCaptureRecorder.RecorderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noAudioSource:
            "No WebKit audio source was available for offline capture."
        case let .tapCreation(status):
            "Failed to create the WebKit process tap (\(status))."
        case .aggregateDeviceCreation:
            "Failed to create the aggregate audio device."
        case let .fileCreation(error):
            "Failed to create the capture file: \(error.localizedDescription)"
        case let .engineStart(status):
            "Failed to start audio capture (\(status))."
        case .audioFormatUnavailable:
            "The capture stream format was unavailable."
        case .timedOut:
            "Timed out while waiting for playback to start or finish."
        case .cancelled:
            "Offline capture was cancelled."
        }
    }
}
