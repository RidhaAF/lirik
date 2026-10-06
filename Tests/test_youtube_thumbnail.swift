//
//  test_youtube_thumbnail.swift
//  lirik
//
//  Unit tests for YouTube thumbnail artwork. Compiles against the REAL
//  sources (not copies) — run with:
//    swiftc Tests/test_youtube_thumbnail.swift \
//      lirik/Sources/Lyrics/AlbumArtService.swift \
//      -o /tmp/thumb_test && /tmp/thumb_test
//

import Foundation
import AppKit

/// URLProtocol stub serving canned per-URL responses.
final class ThumbStubProtocol: URLProtocol {
    static var responses: [String: (status: Int, data: Data)] = [:]
    static var recordedURLs: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.recordedURLs.append(url)
        let stub = Self.responses[url.absoluteString] ?? (404, Data())
        guard let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct YouTubeThumbnailTests {

    static var passCount = 0
    static var failCount = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition {
            passCount += 1
            print("  ✅ \(message)")
        } else {
            failCount += 1
            print("  ❌ FAIL: \(message)")
        }
    }

    /// 1x1 PNG pixels for stubbed image bodies.
    static let pixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    static func makeService() -> AlbumArtService {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lirik-thumb-tests-\(UUID().uuidString)", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ThumbStubProtocol.self]
        return AlbumArtService(session: URLSession(configuration: config), directoryURL: dir)
    }

    static func wideImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 4, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 2).fill()
        image.unlockFocus()
        return image
    }

    static func main() async {
        // ─── Group 1: URL builder ──────────────────────────────────

        print("Group 1: AlbumArtService.thumbnailURLs")

        let urls = AlbumArtService.thumbnailURLs(forVideoId: "dQw4w9WgXcQ").map { $0.absoluteString }
        check(urls == [
            "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg",
            "https://i.ytimg.com/vi/dQw4w9WgXcQ/sddefault.jpg",
            "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        ], "best quality first, hq last-resort (got: \(urls))")

        // ─── Group 2: cropToSquare ─────────────────────────────────

        print("\nGroup 2: AlbumArtService.cropToSquare")

        let squared = AlbumArtService.cropToSquare(wideImage())
        check(squared.size == NSSize(width: 2, height: 2), "4x2 thumbnail crops to 2x2 square (got: \(squared.size))")

        // ─── Group 3: fetch fallback chain ─────────────────────────

        print("\nGroup 3: AlbumArtService.fetchYouTubeThumbnail")

        ThumbStubProtocol.recordedURLs = []
        ThumbStubProtocol.responses = [
            "https://i.ytimg.com/vi/abc123/maxresdefault.jpg": (404, Data()),
            "https://i.ytimg.com/vi/abc123/sddefault.jpg": (200, pixelPNG),
            "https://i.ytimg.com/vi/abc123/hqdefault.jpg": (200, pixelPNG),
        ]
        let service = makeService()
        let image = await service.fetchYouTubeThumbnail(videoId: "abc123")
        check(image != nil, "falls through maxres 404 to sddefault")
        check(ThumbStubProtocol.recordedURLs.count == 2, "stops at first working quality (got: \(ThumbStubProtocol.recordedURLs.count) requests)")
        check(image?.size == NSSize(width: 60, height: 60), "output is 60x60 (got: \(String(describing: image?.size)))")

        // Second call served from cache — no new requests.
        ThumbStubProtocol.recordedURLs = []
        let cached = await service.fetchYouTubeThumbnail(videoId: "abc123")
        check(cached != nil && ThumbStubProtocol.recordedURLs.isEmpty, "cache hit makes no requests")

        // All qualities missing → nil.
        ThumbStubProtocol.recordedURLs = []
        ThumbStubProtocol.responses = [:]
        check(await service.fetchYouTubeThumbnail(videoId: "gone") == nil, "all-404 returns nil")

        // 200 with garbage bytes is skipped, not returned.
        ThumbStubProtocol.responses = [
            "https://i.ytimg.com/vi/bad/maxresdefault.jpg": (200, Data("not an image".utf8)),
            "https://i.ytimg.com/vi/bad/sddefault.jpg": (200, pixelPNG),
        ]
        check(await service.fetchYouTubeThumbnail(videoId: "bad") != nil, "invalid image data falls through")

        // Unsafe ids never hit the network.
        ThumbStubProtocol.recordedURLs = []
        check(await service.fetchYouTubeThumbnail(videoId: "") == nil, "empty id is nil")
        check(await service.fetchYouTubeThumbnail(videoId: "../x") == nil, "path-traversal id is nil")
        check(ThumbStubProtocol.recordedURLs.isEmpty, "rejected ids make no requests")

        print("\n══════════════════════════════════════════════════════")
        print("RESULTS: \(passCount) PASSED, \(failCount) FAILED")
        print("══════════════════════════════════════════════════════")

        if failCount > 0 {
            exit(1)
        }
    }
}
