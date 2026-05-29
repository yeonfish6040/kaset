import Foundation
import Testing
import YouTubeExtraction
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct OfflineStorageManagerTests {
    @Test("Saving a song writes media and manifest data")
    func saveSongWritesMediaAndManifest() async throws {
        let rootURL = try Self.makeTemporaryRoot()
        let manager = OfflineStorageManager(
            rootURL: rootURL,
            skipLoad: true,
            skipPersistence: false
        )
        let client = MockYTMusicClient()
        let song = TestFixtures.makeSong(id: "offline-song", title: "Offline Song")
        let sourceURL = try Self.makeAudioFixture(rootURL: rootURL, fileName: "source.mp3")
        client.playerResponses[song.videoId] = Self.playerResponse(audioURL: sourceURL)

        await manager.saveSong(song, using: client)
        try await Task.sleep(for: .milliseconds(350))

        #expect(client.getPlayerCalled == true)
        #expect(manager.totalSongCount == 1)
        #expect(manager.songRecord(for: song.videoId) != nil)
        #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("media/offline-song.mp3").path))
        #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("index.json").path))
    }

    @Test("Saving a playlist reuses existing songs and only adds mapping data")
    func savePlaylistReusesExistingSongFiles() async throws {
        let rootURL = try Self.makeTemporaryRoot()
        let manager = OfflineStorageManager(
            rootURL: rootURL,
            skipLoad: true,
            skipPersistence: false
        )
        let seedClient = MockYTMusicClient()
        let playlistClient = MockYTMusicClient()
        let song = TestFixtures.makeSong(id: "playlist-song", title: "Playlist Song")
        let sourceURL = try Self.makeAudioFixture(rootURL: rootURL, fileName: "source.mp3")
        seedClient.playerResponses[song.videoId] = Self.playerResponse(audioURL: sourceURL)
        playlistClient.playerResponses[song.videoId] = Self.playerResponse(audioURL: sourceURL)

        let playlist = TestFixtures.makePlaylist(id: "playlist-offline", title: "Offline Playlist")

        await manager.saveSong(song, using: seedClient)
        try await Task.sleep(for: .milliseconds(350))

        await manager.savePlaylist(playlist, tracks: [song], using: playlistClient)
        try await Task.sleep(for: .milliseconds(350))

        #expect(playlistClient.getPlayerCalled == false)
        #expect(manager.totalSongCount == 1)
        #expect(manager.totalPlaylistCount == 1)
        #expect(manager.playlistRecord(for: playlist.id)?.songVideoIds == [song.videoId])

        let playlistMappingURL = rootURL
            .appendingPathComponent("playlists", isDirectory: true)
            .appendingPathComponent("playlist-offline.json")
        #expect(FileManager.default.fileExists(atPath: playlistMappingURL.path))
    }

    @Test("Unplayable tracks are skipped with a clear error")
    func saveSongSkipsUnplayableTrack() async throws {
        let rootURL = try Self.makeTemporaryRoot()
        let manager = OfflineStorageManager(
            rootURL: rootURL,
            skipLoad: true,
            skipPersistence: false
        )
        let client = MockYTMusicClient()
        let song = TestFixtures.makeSong(id: "blocked-song", title: "Blocked Song")
        client.playerResponses[song.videoId] = [
            "playabilityStatus": [
                "status": "UNPLAYABLE",
                "reason": "This video is only available to Music Premium members",
            ],
        ]

        await manager.saveSong(song, using: client)
        try await Task.sleep(for: .milliseconds(100))

        #expect(client.getPlayerCalled == true)
        #expect(manager.totalSongCount == 0)
        #expect(manager.lastErrorMessage?.contains("Music Premium") == true)
        #expect(!FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("media").path))
    }

    @Test("Signature cipher URLs preserve the resolved signature parameter")
    func resolvedStreamURLAppendsCipherSignature() {
        let format: [String: Any] = [
            "signatureCipher": [
                "url=https%3A%2F%2Fr1---sn.example.googlevideo.com%2Fvideoplayback%3Fratebypass%3Dyes",
                "sp=sig",
                "sig=mock-signature",
            ].joined(separator: "&"),
        ]

        let resolvedURL = OfflineStorageManager.url(from: format)

        #expect(resolvedURL?.absoluteString.contains("sig=mock-signature") == true)
        #expect(resolvedURL?.absoluteString.contains("ratebypass=yes") == true)
    }

    @Test("Formats with n challenges require player JavaScript")
    func nChallengeFormatsRequirePlayerJavaScript() {
        let formats: [[String: Any]] = [
            [
                "url": "https://r1---sn.example.googlevideo.com/videoplayback?n=challenge",
                "mimeType": "audio/mp4",
            ],
        ]

        #expect(OfflineStorageManager.requiresPlayerJavaScript(for: formats))
    }

    @Test("Resolved stream URLs append clean GVS PO token")
    func resolvedStreamURLAppendsCleanPOToken() async throws {
        let resolver = YouTubeStreamURLResolver()
        let format: [String: Any] = [
            "url": "https://r1---sn.example.googlevideo.com/videoplayback?ratebypass=yes",
            "mimeType": "audio/mp4",
        ]
        let streamFormat = try #require(YouTubeStreamURLResolver.streamFormat(from: format))

        let resolvedURL = await resolver.resolvedURL(
            from: streamFormat,
            playerJavaScriptURL: nil,
            poToken: "mock-po-token&extra=value"
        )

        #expect(resolvedURL?.absoluteString.contains("ratebypass=yes") == true)
        #expect(resolvedURL?.absoluteString.contains("pot=mock-po-token") == true)
        #expect(resolvedURL?.absoluteString.contains("extra=value") == false)
    }

    private static func makeTemporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaset-offline-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeAudioFixture(rootURL: URL, fileName: String) throws -> URL {
        let url = rootURL.appendingPathComponent(fileName)
        try Data("ID3".utf8).write(to: url)
        return url
    }

    private static func playerResponse(audioURL: URL) -> [String: Any] {
        [
            "playabilityStatus": [
                "status": "OK",
            ],
            "streamingData": [
                "adaptiveFormats": [
                    [
                        "url": audioURL.absoluteString,
                        "mimeType": "audio/mpeg",
                        "bitrate": 128_000,
                        "contentLength": "3",
                    ],
                ],
            ],
        ]
    }
}
