import Foundation
@preconcurrency import JavaScriptCore

// MARK: - YouTubePlayerContext

public struct YouTubePlayerContext: Sendable {
    public let javaScriptURL: URL
    public let signatureTimestamp: Int?

    public init(javaScriptURL: URL, signatureTimestamp: Int?) {
        self.javaScriptURL = javaScriptURL
        self.signatureTimestamp = signatureTimestamp
    }
}

// MARK: - YouTubePlayerContextProvider

public actor YouTubePlayerContextProvider {
    public static let shared = YouTubePlayerContextProvider()

    private let session: URLSession
    private var cachedContext: YouTubePlayerContext?
    private var cachedJavaScript: [URL: String] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func currentContext(videoId: String) async -> YouTubePlayerContext? {
        if let cachedContext {
            return cachedContext
        }

        guard let pageURL = URL(string: "https://www.youtube.com/watch?v=\(videoId)&bpctr=9999999999&has_verified=1"),
              let page = try? await self.fetchString(from: pageURL),
              let javaScriptURL = Self.extractPlayerJavaScriptURL(from: page)
        else {
            return nil
        }

        let javaScript = await self.playerJavaScript(from: javaScriptURL)
        let context = YouTubePlayerContext(
            javaScriptURL: javaScriptURL,
            signatureTimestamp: javaScript.flatMap(Self.extractSignatureTimestamp(from:))
        )
        self.cachedContext = context
        return context
    }

    public func playerJavaScript(from url: URL) async -> String? {
        if let cached = self.cachedJavaScript[url] {
            return cached
        }

        guard let javaScript = try? await self.fetchString(from: url) else {
            return nil
        }

        self.cachedJavaScript[url] = javaScript
        return javaScript
    }

    private func fetchString(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode)
        else {
            throw URLError(.badServerResponse)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }

        return text
    }

    private static func extractPlayerJavaScriptURL(from page: String) -> URL? {
        let patterns = [
            #"(?:"PLAYER_JS_URL"|"jsUrl")\s*:\s*"(?<path>\\?/s/player/[^"]+/base\.js)""#,
            #"(?<path>\\?/s/player/[^"\\]+/base\.js)"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(page.startIndex..., in: page)
            guard let match = regex.firstMatch(in: page, range: range),
                  let pathRange = Range(match.range(withName: "path"), in: page)
            else {
                continue
            }

            let rawPath = String(page[pathRange]).replacingOccurrences(of: #"\/"#, with: "/")
            let absoluteString = rawPath.hasPrefix("http") ? rawPath : "https://www.youtube.com\(rawPath)"
            if let url = URL(string: absoluteString) {
                return url
            }
        }

        return nil
    }

    private static func extractSignatureTimestamp(from javaScript: String) -> Int? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:signatureTimestamp|sts)\s*:\s*(?<sts>[0-9]{5})"#
        ) else {
            return nil
        }

        let range = NSRange(javaScript.startIndex..., in: javaScript)
        guard let match = regex.firstMatch(in: javaScript, range: range),
              let stsRange = Range(match.range(withName: "sts"), in: javaScript)
        else {
            return nil
        }

        return Int(javaScript[stsRange])
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

// MARK: - YouTubeJavaScriptChallengeSolver

public actor YouTubeJavaScriptChallengeSolver {
    public static let shared = YouTubeJavaScriptChallengeSolver()

    private let contextProvider: YouTubePlayerContextProvider
    private var solvedChallenges: [String: String] = [:]
    private var solvedSignatures: [String: String] = [:]
    private var preparedContexts: [URL: JSContext] = [:]

    public init(contextProvider: YouTubePlayerContextProvider = .shared) {
        self.contextProvider = contextProvider
    }

    public func solveNChallenge(_ challenge: String, playerJavaScriptURL: URL) async -> String? {
        let cacheKey = "\(playerJavaScriptURL.absoluteString)#n#\(challenge)"
        if let cached = self.solvedChallenges[cacheKey] {
            return cached
        }

        guard let result = await self.solve(playerJavaScriptURL: playerJavaScriptURL, n: challenge, signature: nil)?.n,
              !result.isEmpty
        else {
            return nil
        }

        self.solvedChallenges[cacheKey] = result
        return result
    }

    public func solveSignature(_ signature: String, playerJavaScriptURL: URL) async -> String? {
        let cacheKey = "\(playerJavaScriptURL.absoluteString)#sig#\(signature)"
        if let cached = self.solvedSignatures[cacheKey] {
            return cached
        }

        guard let result = await self.solve(playerJavaScriptURL: playerJavaScriptURL, n: nil, signature: signature)?.signature,
              !result.isEmpty
        else {
            return nil
        }

        self.solvedSignatures[cacheKey] = result
        return result
    }

    private func solve(
        playerJavaScriptURL: URL,
        n: String?,
        signature: String?
    ) async -> ChallengeResult? {
        guard let context = await self.preparedContext(for: playerJavaScriptURL) else {
            return nil
        }

        let payload = ChallengePayload(n: n, signature: signature)
        guard let payloadData = try? JSONEncoder().encode(payload),
              let payloadJSON = String(data: payloadData, encoding: .utf8)
        else {
            return nil
        }

        let script = """
        (() => {
            const input = \(payloadJSON);
            const url = globalThis.__kasetURLFactory(
                "https://youtube.com/watch?v=yt-dlp-wins",
                "s",
                input.signature ? encodeURIComponent(input.signature) : undefined
            );
            if (input.n) {
                url.set("n", input.n);
            }
            const proto = Object.getPrototypeOf(url);
            const keys = Object.keys(proto).concat(Object.getOwnPropertyNames(proto));
            for (const key of keys) {
                if (!["constructor", "set", "get", "clone"].includes(key)) {
                    url[key]();
                    break;
                }
            }
            const solvedSignature = url.get("s");
            return JSON.stringify({
                n: url.get("n") || null,
                signature: solvedSignature ? decodeURIComponent(solvedSignature) : null
            });
        })()
        """

        guard let result = context.evaluateScript(script)?.toString(),
              let data = result.data(using: .utf8)
        else {
            return nil
        }

        return try? JSONDecoder().decode(ChallengeResult.self, from: data)
    }

    private func preparedContext(for playerJavaScriptURL: URL) async -> JSContext? {
        if let context = self.preparedContexts[playerJavaScriptURL] {
            return context
        }

        guard let javaScript = await self.contextProvider.playerJavaScript(from: playerJavaScriptURL),
              let factoryName = Self.extractURLFactoryName(from: javaScript),
              let context = JSContext()
        else {
            return nil
        }

        context.exceptionHandler = { _, _ in }
        _ = context.evaluateScript(Self.globalStubs)

        let marker = "})(_yt_player);"
        let exposedJavaScript = if javaScript.contains(marker) {
            javaScript.replacingOccurrences(
                of: marker,
                with: ";globalThis.__kasetURLFactory=\(factoryName);\(marker)"
            )
        } else {
            "\(javaScript)\nglobalThis.__kasetURLFactory=\(factoryName);"
        }

        guard context.evaluateScript(exposedJavaScript) != nil,
              context.objectForKeyedSubscript("__kasetURLFactory")?.isUndefined == false
        else {
            return nil
        }

        self.preparedContexts[playerJavaScriptURL] = context
        return context
    }

    private static func extractURLFactoryName(from javaScript: String) -> String? {
        let patterns = [
            #"(?<name>[A-Za-z_$][\w$]*)=function\([^)]*\)\{[^{}]*?new g\.hB\([^{}]*?\.set\("alr","yes"\)"#,
            #"(?<name>[A-Za-z_$][\w$]*)=function\([^)]*\)\{[^{}]*?\.set\("alr","yes"\)"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(javaScript.startIndex..., in: javaScript)
            guard let match = regex.firstMatch(in: javaScript, range: range),
                  let nameRange = Range(match.range(withName: "name"), in: javaScript)
            else {
                continue
            }

            return String(javaScript[nameRange])
        }

        return nil
    }

    private static let globalStubs = """
    globalThis.XMLHttpRequest = globalThis.XMLHttpRequest || function() {};
    globalThis.XMLHttpRequest.prototype = globalThis.XMLHttpRequest.prototype || {};
    globalThis.location = globalThis.location || {
        hash: "",
        host: "www.youtube.com",
        hostname: "www.youtube.com",
        href: "https://www.youtube.com/watch?v=yt-dlp-wins",
        origin: "https://www.youtube.com",
        password: "",
        pathname: "/watch",
        port: "",
        protocol: "https:",
        search: "?v=yt-dlp-wins",
        username: ""
    };
    globalThis.document = globalThis.document || {};
    globalThis.navigator = globalThis.navigator || {};
    globalThis.self = globalThis.self || globalThis;
    globalThis.window = globalThis.window || globalThis;
    """

    private struct ChallengePayload: Encodable {
        let n: String?
        let signature: String?
    }

    private struct ChallengeResult: Decodable {
        let n: String?
        let signature: String?
    }
}

// MARK: - YouTubeStreamURLResolver

public struct YouTubeStreamURLResolver: Sendable {
    private let challengeSolver: YouTubeJavaScriptChallengeSolver

    public init(challengeSolver: YouTubeJavaScriptChallengeSolver = .shared) {
        self.challengeSolver = challengeSolver
    }

    public struct StreamFormat: Sendable {
        public let baseURL: URL
        public let encryptedSignature: String?
        public let signatureParameter: String

        public init(baseURL: URL, encryptedSignature: String?, signatureParameter: String) {
            self.baseURL = baseURL
            self.encryptedSignature = encryptedSignature
            self.signatureParameter = signatureParameter
        }
    }

    public func resolvedURL(
        from format: StreamFormat,
        playerJavaScriptURL: URL?,
        poToken: String?
    ) async -> URL? {
        var url = format.baseURL

        if let encryptedSignature = format.encryptedSignature,
           let playerJavaScriptURL,
           let signature = await self.challengeSolver.solveSignature(
               encryptedSignature,
               playerJavaScriptURL: playerJavaScriptURL
           )
        {
            url = Self.updatingQuery(url, name: format.signatureParameter, value: signature)
        }

        if let nChallenge = Self.queryValue(name: "n", in: url),
           let playerJavaScriptURL,
           let solvedN = await self.challengeSolver.solveNChallenge(
               nChallenge,
               playerJavaScriptURL: playerJavaScriptURL
           )
        {
            url = Self.updatingQuery(url, name: "n", value: solvedN)
        }

        if let poToken = YouTubePOToken.clean(poToken) {
            url = Self.updatingQuery(url, name: "pot", value: poToken)
        }

        return url
    }

    public static func streamFormat(from format: [String: Any]) -> StreamFormat? {
        guard let baseURL = Self.baseURL(from: format) else {
            return nil
        }

        return StreamFormat(
            baseURL: baseURL,
            encryptedSignature: Self.encryptedSignature(from: format),
            signatureParameter: Self.signatureParameter(from: format)
        )
    }

    public static func baseURL(from format: [String: Any]) -> URL? {
        if let urlString = format["url"] as? String {
            return URL(string: urlString)
        }

        guard let cipher = format["signatureCipher"] as? String ?? format["cipher"] as? String,
              let decoded = Self.decodeQueryString(cipher),
              let urlString = decoded["url"]
        else {
            return nil
        }

        guard let url = URL(string: urlString) else {
            return nil
        }

        let signature = decoded["sig"] ?? decoded["signature"]
        let signatureParameter = decoded["sp"] ?? "signature"
        if let signature, !signature.isEmpty {
            return Self.updatingQuery(url, name: signatureParameter, value: signature)
        }

        return url
    }

    public static func encryptedSignature(from format: [String: Any]) -> String? {
        guard let cipher = format["signatureCipher"] as? String ?? format["cipher"] as? String,
              let decoded = decodeQueryString(cipher)
        else {
            return nil
        }

        return decoded["s"]
    }

    public static func signatureParameter(from format: [String: Any]) -> String {
        guard let cipher = format["signatureCipher"] as? String ?? format["cipher"] as? String,
              let decoded = decodeQueryString(cipher)
        else {
            return "signature"
        }

        return decoded["sp"] ?? "signature"
    }

    public static func queryValue(name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    public static func updatingQuery(_ url: URL, name: String, value: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        var items = components.queryItems ?? []
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        return components.url ?? url
    }

    public static func decodeQueryString(_ query: String) -> [String: String]? {
        var result: [String: String] = [:]

        for component in query.split(separator: "&") {
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            result[key] = value
        }

        return result.isEmpty ? nil : result
    }
}

// MARK: - YouTubePOToken

public enum YouTubePOToken {
    public static func configuredPlayerToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.clean(environment["KASET_YOUTUBE_PLAYER_PO_TOKEN"] ?? environment["KASET_YOUTUBE_PO_TOKEN"])
    }

    public static func configuredGVSToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.clean(environment["KASET_YOUTUBE_GVS_PO_TOKEN"] ?? environment["KASET_YOUTUBE_PO_TOKEN"])
    }

    public static func token(from playerResponse: [String: Any]) -> String? {
        if let streamingData = playerResponse["streamingData"] as? [String: Any],
           let serviceIntegrityDimensions = streamingData["serviceIntegrityDimensions"] as? [String: Any],
           let poToken = serviceIntegrityDimensions["poToken"] as? String
        {
            return self.clean(poToken)
        }

        if let serviceIntegrityDimensions = playerResponse["serviceIntegrityDimensions"] as? [String: Any],
           let poToken = serviceIntegrityDimensions["poToken"] as? String
        {
            return self.clean(poToken)
        }

        return nil
    }

    public static func clean(_ token: String?) -> String? {
        guard let token else { return nil }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let delimiters = CharacterSet(charactersIn: "?#&")
        let cleaned = trimmed.components(separatedBy: delimiters).first ?? trimmed
        guard !cleaned.isEmpty else { return nil }

        return cleaned
    }
}
