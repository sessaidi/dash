import AppKit
import ClaudeCodeKit
import DashKit
import Foundation
import UniformTypeIdentifiers

/// A file dropped on (or picked for) the chat, sent with the next message: an image or a PDF as
/// itself, a text file's content inline (secrets masked).
struct ChatAttachment: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// "image/png", "image/jpeg", "image/gif" or "image/webp".
        case image(String)
        case pdf
        case text
    }

    let id = UUID()
    let url: URL
    let kind: Kind
    let data: Data

    var name: String { url.lastPathComponent }

    var icon: String {
        switch kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.text"
        }
    }

    static let imageLimit = 5 * 1024 * 1024
    static let pdfLimit = 20 * 1024 * 1024
    static let textLimit = 256 * 1024
    /// Image types the model reads as is; other images (HEIC, TIFF…) are converted to PNG.
    static let imageTypes: [UTType: String] = [.png: "image/png", .jpeg: "image/jpeg", .gif: "image/gif", .webP: "image/webp"]

    struct Unsupported: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Reads the file and checks it can be sent.
    static func load(_ url: URL) throws -> ChatAttachment {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .fileSizeKey])
        if values.isDirectory == true { throw Unsupported(message: "\(url.lastPathComponent) is a folder: drop files instead.") }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        let size = values.fileSize ?? 0
        func tooBig(_ limit: Int) -> Unsupported {
            Unsupported(message: "\(url.lastPathComponent) is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)); the limit is \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)).")
        }
        if let media = imageTypes.first(where: { type.conforms(to: $0.key) })?.value {
            guard size <= imageLimit else { throw tooBig(imageLimit) }
            return ChatAttachment(url: url, kind: .image(media), data: try Data(contentsOf: url))
        }
        if type.conforms(to: .image) {
            guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                throw Unsupported(message: "\(url.lastPathComponent) couldn't be read as an image.")
            }
            guard png.count <= imageLimit else { throw tooBig(imageLimit) }
            return ChatAttachment(url: url, kind: .image("image/png"), data: png)
        }
        if type.conforms(to: .pdf) {
            guard size <= pdfLimit else { throw tooBig(pdfLimit) }
            return ChatAttachment(url: url, kind: .pdf, data: try Data(contentsOf: url))
        }
        guard size <= textLimit else { throw tooBig(textLimit) }
        let data = try Data(contentsOf: url)
        // Text, code, JSON, logs…: anything that reads as UTF-8 without NUL bytes.
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw Unsupported(message: "\(url.lastPathComponent) isn't an image, a PDF or a text file.")
        }
        return ChatAttachment(url: url, kind: .text, data: data)
    }

    /// The content block sent to the model.
    var block: ClaudeCodeKit.JSON {
        switch kind {
        case .image(let media):
            ["type": "image", "source": ["type": "base64", "media_type": .string(media), "data": .string(data.base64EncodedString())]]
        case .pdf:
            ["type": "document", "title": .string(name),
             "source": ["type": "base64", "media_type": "application/pdf", "data": .string(data.base64EncodedString())]]
        case .text:
            ["type": "text", "text": .string("<attachment name=\"\(name)\">\n\(Sanitizer.clean(String(decoding: data, as: UTF8.self)))\n</attachment>")]
        }
    }
}
