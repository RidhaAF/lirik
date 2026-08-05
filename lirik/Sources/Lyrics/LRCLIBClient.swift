//
//  LRCLIBClient.swift
//  lirik
//
//  Primary lyrics source fetching synced/plain lyrics from LRCLIB REST API.
//  Uses async/await for network calls per AGENTS.md §5.
//

import Foundation

/// Explicit result of an LRCLIB lookup — handles "no match found" explicitly
/// per prompt requirements, rather than throwing errors to be swallowed.
enum LRCLIBResult: Sendable, Equatable {
    /// Synced LRC lyrics found.
    case synced(id: Int, lrcText: String, plainLyrics: String?)
    /// Only plain text lyrics found (not time-synced).
    case plainOnly(id: Int, plainText: String)
    /// Explicitly no lyrics found on LRCLIB (HTTP 404).
    case notFound
}

/// Errors that represent actual network or system failures (not "not found").
enum LRCLIBError: Error, LocalizedError, Equatable {
    case invalidURL
    case networkError(String)
    case rateLimited
    case serverError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid LRCLIB API URL request."
        case .networkError(let message):
            return "Network request failed: \(message)"
        case .rateLimited:
            return "LRCLIB rate limit exceeded (HTTP 429)."
        case .serverError(let code):
            return "LRCLIB server error (HTTP \(code))."
        }
    }
}

/// DTO for decoding LRCLIB JSON API responses.
private struct LRCLIBResponseDTO: Decodable {
    let id: Int
    let name: String?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

/// Client for LRCLIB REST API (`https://lrclib.net/api/get`).
final class LRCLIBClient: Sendable {

    private let baseURL = "https://lrclib.net/api/get"
    private let userAgent = "Lirik/1.0 (macOS TouchBar Lyric Widget)"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Sanitizes track titles by stripping common noise like "(Remastered 2021)", "- Live", "[feat. ...]"
    static func cleanTrackTitle(_ title: String) -> String {
        var cleaned = title
        let patterns = [
            "\\s*\\(.*remaster.*\\)",
            "\\s*\\[.*remaster.*\\]",
            "\\s*\\(.*deluxe.*\\)",
            "\\s*\\[.*deluxe.*\\]",
            "\\s*\\(.*edition.*\\)",
            "\\s*\\(.*live.*\\)",
            "\\s*-\\s*live.*",
            "\\s*-\\s*remastered.*",
            "\\s*\\(feat\\..*\\)",
            "\\s*\\[feat\\..*\\]",
            "\\s*ft\\..*"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: cleaned.utf16.count)
                cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
            }
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    /// Fetches lyrics from LRCLIB given track metadata.
    func fetchLyrics(
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval? = nil
    ) async throws -> LRCLIBResult {
        let result = try await queryAPI(title: title, artist: artist, album: album, duration: duration)
        if case .notFound = result {
            let cleaned = Self.cleanTrackTitle(title)
            if !cleaned.isEmpty && cleaned != title {
                NSLog("[LRCLIBClient] Retrying lookup with sanitized title: '\(cleaned)'")
                return try await queryAPI(title: cleaned, artist: artist, album: nil, duration: duration)
            }
        }
        return result
    }

    private func queryAPI(
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval? = nil
    ) async throws -> LRCLIBResult {
        guard var components = URLComponents(string: baseURL) else {
            throw LRCLIBError.invalidURL
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]

        if let album = album, !album.isEmpty {
            queryItems.append(URLQueryItem(name: "album_name", value: album))
        }

        if let duration = duration, duration > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw LRCLIBError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10.0

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LRCLIBError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LRCLIBError.networkError("Invalid HTTP response")
        }

        switch httpResponse.statusCode {
        case 200:
            let dto = try JSONDecoder().decode(LRCLIBResponseDTO.self, from: data)

            if let synced = dto.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .synced(id: dto.id, lrcText: synced, plainLyrics: dto.plainLyrics)
            } else if let plain = dto.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .plainOnly(id: dto.id, plainText: plain)
            } else {
                return .notFound
            }

        case 404:
            return .notFound

        case 429:
            throw LRCLIBError.rateLimited

        default:
            throw LRCLIBError.serverError(statusCode: httpResponse.statusCode)
        }
    }
}
