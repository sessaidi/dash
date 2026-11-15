import DashKit
import Foundation
import SwiftUI

extension ExtensionHost {
    /// Plugins' Markdown (PR descriptions, reviews) drawn by the note renderer, read-only.
    func markdown(_ text: String) -> AnyView {
        AnyView(NoteRenderer(source: HostMarkdown.clean(text)).environment(self))
    }
}

/// Markdown written for GitHub, made ready for the note renderer.
enum HostMarkdown {
    /// Leaves out HTML comments (PR templates' instructions), turns `<details><summary>` into a bold
    /// line followed by its content, and `<br>` into line breaks.
    static func clean(_ text: String) -> String {
        var text = text.replacing(/<!--[\s\S]*?-->/, with: "")
        text = text.replacing(/<summary>\s*([\s\S]*?)\s*<\/summary>/.ignoresCase(), with: { "**\($0.output.1)**\n" })
        text = text.replacing(/<\/?details[^>]*>/.ignoresCase(), with: "")
        text = text.replacing(/<br\s*\/?>/.ignoresCase(), with: "  \n")
        // Three or more blank lines (left by removed comments) become one.
        text = text.replacing(/\n{3,}/, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
