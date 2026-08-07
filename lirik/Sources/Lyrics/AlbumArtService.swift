//
//  AlbumArtService.swift
//  lirik
//
//  Fetches album cover artwork from the iTunes Search API.
//  Free, no auth required. Caches images on disk and in memory.
//
//  Keyed by SHA256("artist|album") — same pattern as LyricsCache.
//

import Foundation
import AppKit
import CryptoKit

/// Fetches and caches album artwork from the iTunes Search API.
final class AlbumArtService: @unchecked Sendable {

    // MARK: - Cache

    /// In-memory cache for instant access to recently-used artwork.
    private let memoryCache = NSCache<NSString, NSImage>()

    /// Directory for on-disk artwork cache.
    private let diskCacheDir: URL

    /// Tracks in-flight requests to avoid duplicate network calls.
    /// Key → Task mapping ensures only one request per unique album.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let lock = NSLock()

    // MARK: - Init

    init() {
        let userCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.diskCacheDir = userCaches
            .appendingPathComponent("io.github.ridhaaf.lirik", isDirectory: true)
            .appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)

        memoryCache.countLimit = 30 // Keep last 30 artworks in memory
    }

    // MARK: - Public API

    /// Fetches album artwork for the given artist and album.
    /// Returns nil if no artwork is found or the request fails.
    func fetchArtwork(artist: String, album: String?) async -> NSImage? {
        guard let album, !album.isEmpty else { return nil }

        let key = Self.makeArtworkKey(artist: artist, album: album)

        // 1. Check memory cache
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // 2. Check disk cache
        if let diskImage = loadFromDisk(key: key) {
            memoryCache.setObject(diskImage, forKey: key as NSString)
            return diskImage
        }

        // 3. Dedup in-flight requests
        lock.lock()
        if let existing = inFlight[key] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<NSImage?, Never> { [weak self] in
            await self?.performFetch(artist: artist, album: album, key: key)
        }
        inFlight[key] = task
        lock.unlock()

        let image = await task.value

        lock.lock()
        inFlight.removeValue(forKey: key)
        lock.unlock()

        // 4. Cache in memory if successful
        if let image {
            memoryCache.setObject(image, forKey: key as NSString)
        }

        return image
    }

    // MARK: - Key generation

    /// Generates a stable cache key from artist + album.
    static func makeArtworkKey(artist: String, album: String) -> String {
        let normArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let signature = "\(normArtist)|\(normAlbum)"
        let digest = SHA256.hash(data: Data(signature.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Network fetch

    /// Performs the actual iTunes API → image download pipeline.
    /// Tries multiple query strategies in order:
    /// 1. artist + album (entity=album)
    /// 2. artist + album (entity=musicTrack) — better for EPs/singles
    /// 3. artist only (entity=album) — broadest fallback
    private func performFetch(artist: String, album: String, key: String) async -> NSImage? {
        // Strategy 1: artist + album, entity=album
        if let image = await searchAndDownload(artist: artist, album: album, entity: "album", cacheKey: key) {
            return image
        }

        // Strategy 2: artist + album, entity=musicTrack (catches EPs, singles, deluxe variants)
        if let image = await searchAndDownload(artist: artist, album: album, entity: "musicTrack", cacheKey: key) {
            return image
        }

        // Strategy 3: artist only, entity=album (broadest fallback)
        if let image = await searchAndDownload(artist: artist, album: nil, entity: "album", cacheKey: key) {
            return image
        }

        NSLog("[AlbumArtService] All strategies exhausted for artist='\(artist)' album='\(album)'")
        return nil
    }

    /// Performs a single iTunes API search + download attempt.
    private func searchAndDownload(artist: String, album: String?, entity: String, cacheKey: String) async -> NSImage? {
        let query: String
        if let album, !album.isEmpty {
            query = "\(artist) \(album)"
        } else {
            query = artist
        }

        guard let encoded = query.trimmingCharacters(in: .whitespaces)
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }

        guard let searchURL = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=\(entity)&limit=1") else {
            return nil
        }

        let searchData: Data
        do {
            let (data, response) = try await URLSession.shared.data(from: searchURL)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            searchData = data
        } catch {
            NSLog("[AlbumArtService] Search failed (\(entity)): \(error.localizedDescription)")
            return nil
        }

        // Parse
        struct SearchResult: Codable {
            let results: [AlbumResult]
        }
        struct AlbumResult: Codable {
            let artworkUrl60: String?
            let artworkUrl100: String?
            let collectionName: String?
            let trackName: String?
        }

        guard let searchResult = try? JSONDecoder().decode(SearchResult.self, from: searchData),
              let first = searchResult.results.first,
              let artworkURLString = first.artworkUrl100 ?? first.artworkUrl60,
              let artworkURL = URL(string: artworkURLString) else {
            NSLog("[AlbumArtService] No results for query='\(query)' entity=\(entity)")
            return nil
        }

        NSLog("[AlbumArtService] Found artwork for query='\(query)' entity=\(entity) → \(first.collectionName ?? first.trackName ?? "unknown")")

        // Download
        do {
            let (imageData, _) = try await URLSession.shared.data(from: artworkURL)
            guard let image = NSImage(data: imageData) else { return nil }
            let resized = resizeImage(image, to: NSSize(width: 60, height: 60))
            saveToDisk(key: cacheKey, image: resized)
            return resized
        } catch {
            NSLog("[AlbumArtService] Image download failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Disk cache

    private func diskCacheURL(for key: String) -> URL {
        return diskCacheDir.appendingPathComponent("\(key).png")
    }

    private func loadFromDisk(key: String) -> NSImage? {
        let url = diskCacheURL(for: key)
        guard let image = NSImage(contentsOf: url) else { return nil }
        return image
    }

    private func saveToDisk(key: String, image: NSImage) {
        let url = diskCacheURL(for: key)
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            return
        }
        try? pngData.write(to: url, options: .atomic)
    }

    // MARK: - Image resize

    private func resizeImage(_ image: NSImage, to size: NSSize) -> NSImage {
        let resized = NSImage(size: size)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        return resized
    }

    /// Clears all cached artwork from memory and disk.
    func clear() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskCacheDir)
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
    }
}
