import Foundation

/// HLS プレイリスト（.m3u8）の解析
public struct ByteRange: Equatable {
    public var length: Int
    public var offset: Int
}

public struct M3U8Variant {
    public var uri: URL
    public var bandwidth: Int
    public var codecs: String?
    public var resolution: String?
    public var audioGroup: String?
}

public struct M3U8Rendition {
    public var type: String
    public var groupID: String
    public var uri: URL?
    public var isDefault: Bool
}

public struct M3U8Key: Equatable {
    public var method: String
    public var uri: URL?
    public var iv: Data?
}

public struct M3U8Map: Equatable {
    public var uri: URL
    public var byteRange: ByteRange?
    public var key: M3U8Key?
}

public struct M3U8Segment {
    public var uri: URL
    public var duration: Double
    public var byteRange: ByteRange?
    public var key: M3U8Key?
    public var map: M3U8Map?
    public var sequence: Int
}

public enum M3U8Playlist {
    case master(variants: [M3U8Variant], renditions: [M3U8Rendition])
    case media(segments: [M3U8Segment], isEnded: Bool)
}

public enum M3U8Parser {
    public static func parse(_ text: String, baseURL: URL) throws -> M3U8Playlist {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, first.hasPrefix("#EXTM3U") else {
            throw HLSError.invalidPlaylist
        }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            return parseMaster(lines, baseURL: baseURL)
        }
        return try parseMedia(lines, baseURL: baseURL)
    }

    private static func resolve(_ s: String, _ base: URL) -> URL? {
        URL(string: s, relativeTo: base)?.absoluteURL
            ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s, relativeTo: base)?.absoluteURL
    }

    private static func parseMaster(_ lines: [String], baseURL: URL) -> M3U8Playlist {
        var variants: [M3U8Variant] = []
        var renditions: [M3U8Rendition] = []
        var pending: [String: String]?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                renditions.append(M3U8Rendition(
                    type: a["TYPE"] ?? "",
                    groupID: a["GROUP-ID"] ?? "",
                    uri: a["URI"].flatMap { resolve($0, baseURL) },
                    isDefault: a["DEFAULT"] == "YES"
                ))
            } else if !line.hasPrefix("#"), let a = pending {
                if let uri = resolve(line, baseURL) {
                    variants.append(M3U8Variant(
                        uri: uri,
                        bandwidth: Int(a["BANDWIDTH"] ?? "") ?? Int(a["AVERAGE-BANDWIDTH"] ?? "") ?? 0,
                        codecs: a["CODECS"],
                        resolution: a["RESOLUTION"],
                        audioGroup: a["AUDIO"]
                    ))
                }
                pending = nil
            }
        }
        return .master(variants: variants, renditions: renditions)
    }

    private static func parseMedia(_ lines: [String], baseURL: URL) throws -> M3U8Playlist {
        var segments: [M3U8Segment] = []
        var sequence = 0
        var duration = 0.0
        var key: M3U8Key?
        var map: M3U8Map?
        var range: ByteRange?
        var lastRangeEnd: [URL: Int] = [:]
        var pendingRange: (length: Int, offset: Int?)?
        var ended = false

        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                let v = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
                duration = Double(v.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let v = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                let parts = v.split(separator: "@")
                if let len = Int(parts[0]) {
                    pendingRange = (len, parts.count > 1 ? Int(parts[1]) : nil)
                }
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let a = attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = a["METHOD"] ?? "NONE"
                if method == "NONE" {
                    key = nil
                } else {
                    key = M3U8Key(method: method,
                                  uri: a["URI"].flatMap { resolve($0, baseURL) },
                                  iv: a["IV"].flatMap(hexData))
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let a = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let uriString = a["URI"], let uri = resolve(uriString, baseURL) else { continue }
                var r: ByteRange?
                if let br = a["BYTERANGE"] {
                    let parts = br.split(separator: "@")
                    if let len = Int(parts[0]) {
                        r = ByteRange(length: len, offset: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
                    }
                }
                map = M3U8Map(uri: uri, byteRange: r, key: key)
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                ended = true
            } else if !line.hasPrefix("#") {
                guard let uri = resolve(line, baseURL) else { continue }
                if let p = pendingRange {
                    let offset = p.offset ?? lastRangeEnd[uri] ?? 0
                    range = ByteRange(length: p.length, offset: offset)
                    lastRangeEnd[uri] = offset + p.length
                } else {
                    range = nil
                }
                segments.append(M3U8Segment(uri: uri, duration: duration, byteRange: range,
                                            key: key, map: map, sequence: sequence))
                sequence += 1
                duration = 0
                pendingRange = nil
            }
        }
        return .media(segments: segments, isEnded: ended)
    }

    /// KEY=VALUE,KEY="VALUE,with,commas" 形式を辞書にする
    static func attributes(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var inQuotes = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { result[k] = value }
            key = ""
            value = ""
            inKey = true
        }
        for ch in s {
            if inKey {
                if ch == "=" { inKey = false } else if ch == "," { flush() } else { key.append(ch) }
            } else if inQuotes {
                if ch == "\"" { inQuotes = false } else { value.append(ch) }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                flush()
            } else {
                value.append(ch)
            }
        }
        flush()
        return result
    }

    static func hexData(_ s: String) -> Data? {
        var hex = s.lowercased()
        if hex.hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
        if hex.count % 2 == 1 { hex = "0" + hex }
        var data = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            data.append(b)
            i = j
        }
        if data.count < 16 { data = Data(repeating: 0, count: 16 - data.count) + data }
        return Data(data.suffix(16))
    }
}
