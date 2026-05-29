import Foundation
import Observation
import YouTubeExtraction

/// Manages offline playlist/song storage and media downloads.
@MainActor
@Observable
final class OfflineStorageManager {
    static let shared = OfflineStorageManager()

    enum Constants {
        static let folderName = "offline-storage"
        static let indexFileName = "index.json"
        static let playlistsFolderName = "playlists"
        static let songsFolderName = "songs"
        static let mediaFolderName = "media"
        static let manifestVersion = 1
        static let debounceInterval: Duration = .milliseconds(120)
        static let maxConcurrentDownloads = 3
    }

    struct OfflinePlaylistRecord: Codable, Hashable, Identifiable {
        let id: String
        let playlist: Playlist
        let savedAt: Date
        let songVideoIds: [String]

        var songCount: Int {
            self.songVideoIds.count
        }
    }

    struct OfflineSongRecord: Codable, Hashable, Identifiable {
        let id: String
        let song: Song
        let savedAt: Date
        let fileName: String
        let fileExtension: String
        let mimeType: String
        let byteCount: Int64
        let sourcePlaylistIds: [String]
        let sourcePlaylistTitles: [String]

        var videoId: String {
            self.id
        }
    }

    struct OfflineManifest: Codable {
        var version: Int
        var updatedAt: Date
        var libraryPlaylists: [Playlist]
        var playlists: [OfflinePlaylistRecord]
        var songs: [OfflineSongRecord]
    }

    struct DownloadedAudio {
        let fileName: String
        let fileExtension: String
        let mimeType: String
        let byteCount: Int64
    }

    let fileManager: FileManager
    let rootURL: URL
    let skipPersistence: Bool
    let streamURLResolver: YouTubeStreamURLResolver

    var manifest: OfflineManifest
    var saveTask: Task<Void, Never>?

    var isSyncing = false
    var progressMessage: String = ""
    var lastSyncDate: Date?
    var lastErrorMessage: String?

    init(
        rootURL: URL? = nil,
        skipLoad: Bool = UITestConfig.isUITestMode,
        skipPersistence: Bool = UITestConfig.isUITestMode
    ) {
        self.fileManager = .default
        self.rootURL = rootURL ?? Self.defaultRootURL()
        self.skipPersistence = skipPersistence
        self.streamURLResolver = YouTubeStreamURLResolver()
        self.manifest = OfflineManifest(
            version: Self.Constants.manifestVersion,
            updatedAt: .distantPast,
            libraryPlaylists: [],
            playlists: [],
            songs: []
        )

        if !skipLoad {
            self.load()
        }
    }

    var libraryPlaylists: [Playlist] {
        self.manifest.libraryPlaylists
    }

    var playlists: [OfflinePlaylistRecord] {
        self.manifest.playlists.sorted { $0.savedAt > $1.savedAt }
    }

    var songs: [OfflineSongRecord] {
        self.manifest.songs.sorted { $0.savedAt > $1.savedAt }
    }

    var totalSongCount: Int {
        self.manifest.songs.count
    }

    var totalPlaylistCount: Int {
        self.manifest.playlists.count
    }

    func refreshLibraryPlaylists(using client: any YTMusicClientProtocol) async {
        do {
            let playlists = try await client.getLibraryPlaylists()
            self.manifest.libraryPlaylists = playlists
            self.manifest.updatedAt = Date()
            self.save()

            if SettingsManager.shared.offlineStorageEnabled {
                await self.syncLibraryPlaylists(using: client, playlists: playlists)
            }
        } catch {
            self.lastErrorMessage = error.localizedDescription
            DiagnosticsLogger.ui.error("Failed to refresh library playlists for offline storage: \(error.localizedDescription)")
        }
    }

    func syncLibraryPlaylists(
        using client: any YTMusicClientProtocol,
        playlists: [Playlist]? = nil
    ) async {
        guard SettingsManager.shared.offlineStorageEnabled else { return }
        guard !self.isSyncing else { return }

        let libraryPlaylists = playlists ?? self.manifest.libraryPlaylists
        guard !libraryPlaylists.isEmpty else { return }

        self.isSyncing = true
        self.progressMessage = String(localized: "Syncing offline storage...")
        defer {
            self.isSyncing = false
            self.progressMessage = ""
            self.lastSyncDate = Date()
            self.save()
        }

        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for playlist in libraryPlaylists {
                guard !Task.isCancelled else { break }

                if inFlight >= Self.Constants.maxConcurrentDownloads {
                    await group.next()
                    inFlight -= 1
                }

                group.addTask { [client] in
                    await self.savePlaylist(playlist, using: client)
                }
                inFlight += 1
            }

            await group.waitForAll()
        }
    }

    func savePlaylist(_ playlist: Playlist, using client: any YTMusicClientProtocol) async {
        do {
            let tracks = try await client.getPlaylistAllTracks(playlistId: playlist.id)
            await self.savePlaylist(playlist, tracks: tracks, using: client)
        } catch {
            self.lastErrorMessage = error.localizedDescription
            DiagnosticsLogger.ui.error("Failed to fetch playlist tracks for offline storage: \(error.localizedDescription)")
        }
    }

    func savePlaylist(
        _ playlist: Playlist,
        tracks: [Song],
        using client: any YTMusicClientProtocol
    ) async {
        let cleanedTracks = tracks.filter(\.isPlayable)
        let songVideoIds = cleanedTracks.map(\.videoId)
        let existingSongs = Dictionary(uniqueKeysWithValues: self.manifest.songs.map { ($0.id, $0) })
        let existingPlaylist = self.manifest.playlists.first { $0.id == playlist.id }
        let sourcePlaylistIDs = [playlist.id]
        let sourcePlaylistTitles = [playlist.title]

        var resolvedSongs: [OfflineSongRecord] = []
        await withTaskGroup(of: OfflineSongRecord?.self) { group in
            for song in cleanedTracks {
                group.addTask {
                    await self.resolveSongRecord(
                        song: song,
                        sourcePlaylistIDs: sourcePlaylistIDs,
                        sourcePlaylistTitles: sourcePlaylistTitles,
                        existingRecord: existingSongs[song.videoId],
                        client: client
                    )
                }
            }

            for await record in group {
                if let record {
                    resolvedSongs.append(record)
                }
            }
        }

        self.mergeOfflineResults(
            playlist: playlist,
            songVideoIds: songVideoIds,
            resolvedSongs: resolvedSongs,
            existingPlaylist: existingPlaylist
        )
    }

    func saveSong(_ song: Song, using client: any YTMusicClientProtocol) async {
        let existingSong = self.manifest.songs.first { $0.id == song.videoId }
        if let record = await self.resolveSongRecord(
            song: song,
            sourcePlaylistIDs: [],
            sourcePlaylistTitles: [],
            existingRecord: existingSong,
            client: client
        ) {
            self.upsert(songRecord: record)
            self.save()
        }
    }

    func removeSong(videoId: String) {
        self.manifest.songs.removeAll { $0.id == videoId }
        for index in self.manifest.playlists.indices {
            self.manifest.playlists[index] = OfflinePlaylistRecord(
                id: self.manifest.playlists[index].id,
                playlist: self.manifest.playlists[index].playlist,
                savedAt: self.manifest.playlists[index].savedAt,
                songVideoIds: self.manifest.playlists[index].songVideoIds.filter { $0 != videoId }
            )
        }
        self.deleteSongFiles(videoId: videoId)
        self.save()
    }

    func removePlaylist(playlistId: String) {
        self.manifest.playlists.removeAll { $0.id == playlistId }
        self.deletePlaylistMappingFile(playlistId: playlistId)
        self.save()
    }

    private func resolveSongRecord(
        song: Song,
        sourcePlaylistIDs: [String],
        sourcePlaylistTitles: [String],
        existingRecord: OfflineSongRecord?,
        client: any YTMusicClientProtocol
    ) async -> OfflineSongRecord? {
        do {
            if let existingRecord,
               self.fileManager.fileExists(atPath: self.mediaFileURL(for: existingRecord).path)
            {
                return self.mergedSongRecord(
                    existingRecord,
                    sourcePlaylistIDs: sourcePlaylistIDs,
                    sourcePlaylistTitles: sourcePlaylistTitles
                )
            }

            let playerResponse = try await client.getPlayer(videoId: song.videoId)
            if let playabilityMessage = Self.playabilityMessage(from: playerResponse) {
                self.lastErrorMessage = playabilityMessage
                DiagnosticsLogger.ui.warning(
                    "Skipping offline download for \(song.title, privacy: .public): \(playabilityMessage, privacy: .public)"
                )
                return nil
            }

            let candidateFormats = Self.bestStreamFormats(from: playerResponse)
            guard !candidateFormats.isEmpty else {
                self.lastErrorMessage = "No downloadable audio stream available for \(song.title)"
                return nil
            }
            let playerContext: YouTubePlayerContext? = if Self.requiresPlayerJavaScript(for: candidateFormats) {
                await YouTubePlayerContextProvider.shared.currentContext(videoId: song.videoId)
            } else {
                nil
            }
            let poToken = YouTubePOToken.token(from: playerResponse) ?? YouTubePOToken.configuredGVSToken()

            let downloaded = await self.downloadOfflineAudio(
                song: song,
                candidateFormats: candidateFormats,
                client: client,
                playerJavaScriptURL: playerContext?.javaScriptURL,
                poToken: poToken
            )
            guard let downloaded else {
                self.lastErrorMessage = "Failed to download audio for \(song.title)"
                return nil
            }

            return OfflineSongRecord(
                id: song.videoId,
                song: song,
                savedAt: Date(),
                fileName: downloaded.fileName,
                fileExtension: downloaded.fileExtension,
                mimeType: downloaded.mimeType,
                byteCount: downloaded.byteCount,
                sourcePlaylistIds: sourcePlaylistIDs,
                sourcePlaylistTitles: sourcePlaylistTitles
            )
        } catch {
            self.lastErrorMessage = error.localizedDescription
            DiagnosticsLogger.ui.error(
                "Failed to save offline song \(song.title, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func downloadOfflineAudio(
        song: Song,
        candidateFormats: [[String: Any]],
        client: any YTMusicClientProtocol,
        playerJavaScriptURL: URL?,
        poToken: String?
    ) async -> DownloadedAudio? {
        for streamFormat in candidateFormats {
            guard let parsedStreamFormat = YouTubeStreamURLResolver.streamFormat(from: streamFormat) else {
                continue
            }

            guard let streamURL = await self.streamURLResolver.resolvedURL(
                from: parsedStreamFormat,
                playerJavaScriptURL: playerJavaScriptURL,
                poToken: poToken
            ) else {
                continue
            }

            let mimeType = (streamFormat["mimeType"] as? String) ?? ""

            do {
                return if let authenticatedClient = client as? YTMusicClient {
                    try await authenticatedClient.downloadAuthenticatedAudio(
                        from: streamURL,
                        mimeType: mimeType,
                        song: song,
                        rootURL: self.rootURL,
                        fileManager: self.fileManager
                    )
                } else {
                    try await Self.downloadAudio(
                        from: streamURL,
                        mimeType: mimeType,
                        song: song,
                        rootURL: self.rootURL,
                        fileManager: self.fileManager
                    )
                }
            } catch {
                DiagnosticsLogger.ui.warning(
                    "Download failed for \(song.title, privacy: .public) on candidate format: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return nil
    }
}
