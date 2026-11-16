import AppKit
import Foundation
import Testing
@testable import Dash

/// Files dropped on the chat: what each becomes, and what's refused.
struct ChatAttachmentTests {
    private func file(_ name: String, _ data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test func textIsInlinedWithSecretsMasked() throws {
        let attachment = try ChatAttachment.load(try file("notes.md", Data("token: ghp_abcdefghijklmnopqrstuvwxyz0123456789\nhello".utf8)))
        #expect(attachment.kind == .text)
        let text = attachment.block["text"]?.string ?? ""
        #expect(text.hasPrefix("<attachment name=\"notes.md\">") && text.contains("hello"))
        #expect(!text.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    @Test func imagesAndPDFsAreSentAsThemselves() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let attachment = try ChatAttachment.load(try file("shot.png", png))
        #expect(attachment.kind == .image("image/png"))
        #expect(attachment.block["source"]?["media_type"]?.string == "image/png")
        let tiff = try ChatAttachment.load(try file("shot.tiff", image.tiffRepresentation!))
        #expect(tiff.kind == .image("image/png"))
        let pdf = try ChatAttachment.load(try file("spec.pdf", Data("%PDF-1.4\n".utf8)))
        #expect(pdf.kind == .pdf && pdf.block["type"]?.string == "document")
    }

    @Test func binaryAndFoldersAreRefused() throws {
        #expect(throws: ChatAttachment.Unsupported.self) { try ChatAttachment.load(try file("blob.bin", Data([0, 1, 2, 0]))) }
        #expect(throws: ChatAttachment.Unsupported.self) { try ChatAttachment.load(FileManager.default.temporaryDirectory) }
    }
}
