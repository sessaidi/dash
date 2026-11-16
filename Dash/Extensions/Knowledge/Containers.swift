import DashKit
import Foundation

/// Container images a repository builds on: a Dockerfile's base images (`FROM`, `ARG` defaults
/// filled in, build stages and `scratch` left out) and docker-compose `image:`s, as
/// `file —uses_image→ image:<name>`. The final stage's exposed ports, entrypoint and command become
/// a `container` ref on the Dockerfile's service, which the link pass adds to its signature.
struct ContainerExtractor: CodeExtractor {
    let name = "containers"
    var sharedKinds: [String] { ["image"] }
    static let refKind = "container"

    static func imageNode(_ name: String) -> KnowledgeNode {
        KnowledgeNode(id: "image:" + name, kind: "image", name: name, qualified: name, signature: "Container image " + name, source: "code")
    }

    func accepts(path: String, language: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return language == "dockerfile" || (language == "yaml" && (name.hasPrefix("docker-compose") || name.hasPrefix("compose.")))
    }

    func extract(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        let images: [String]
        if file.language == "dockerfile" {
            let dockerfile = Self.dockerfile(file.text)
            images = dockerfile.images
            if !dockerfile.facts.isEmpty {
                let service = ServiceExtractor.dockerfileService(file)
                result.refs.append(KnowledgeRef(src: ServiceExtractor.id(repo: file.repoID, name: service.name), kind: Self.refKind, names: dockerfile.facts))
            }
        } else {
            images = (YAMLTree.parse(file.text)?["services"]?.entries ?? []).compactMap { $0.node["image"]?.string.flatMap(RuntimeExtractor.imageName) }
        }
        for image in Set(images).sorted() {
            result.nodes.append(Self.imageNode(image))
            result.edges.append(KnowledgeEdge(src: file.fileID, dst: "image:" + image, kind: "uses_image"))
        }
        return result
    }

    /// Base images, and the final stage's facts: "port=8080", "entrypoint=…", "cmd=…".
    static func dockerfile(_ text: String) -> (images: [String], facts: [String]) {
        var arguments: [String: String] = [:]
        var stages = Set<String>()
        var images: [String] = []
        var ports: [String] = []
        var entrypoint: String?
        var command: String?
        for line in instructions(text) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let keyword = parts.first?.uppercased() else { continue }
            let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch keyword {
            case "ARG":
                let definition = rest.split(separator: "=", maxSplits: 1).map(String.init)
                if definition.count == 2 { arguments[definition[0]] = SourceScan.literal(definition[1]) ?? definition[1] }
            case "FROM":
                let tokens = rest.split(separator: " ").map(String.init).filter { !$0.hasPrefix("--") }
                guard let reference = tokens.first else { continue }
                var image = reference
                for (name, value) in arguments { image = image.replacingOccurrences(of: "${\(name)}", with: value).replacingOccurrences(of: "$\(name)", with: value) }
                ports = []
                entrypoint = nil
                command = nil
                if !stages.contains(image.lowercased()), image.lowercased() != "scratch", let name = RuntimeExtractor.imageName(image) { images.append(name) }
                if tokens.count >= 3, tokens[1].lowercased() == "as" { stages.insert(tokens[2].lowercased()) }
            case "EXPOSE":
                ports += rest.split(separator: " ").map { String($0.split(separator: "/").first ?? $0) }.filter { !$0.isEmpty }
            case "ENTRYPOINT":
                entrypoint = commandLine(rest)
            case "CMD":
                command = commandLine(rest)
            default:
                break
            }
        }
        var facts = ports.map { "port=" + $0 }
        if let entrypoint, !entrypoint.isEmpty { facts.append("entrypoint=" + entrypoint) }
        if let command, !command.isEmpty { facts.append("cmd=" + command) }
        return (images, facts)
    }

    /// Instructions with continuation lines joined and comments dropped.
    static func instructions(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || (line.isEmpty && current.isEmpty) { continue }
            if line.hasSuffix("\\") {
                current += line.dropLast() + " "
                continue
            }
            result.append(current + line)
            current = ""
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// `["/app/server", "--port", "8080"]` or a shell form, as one line (secrets masked, ≤ 160 characters).
    static func commandLine(_ text: String) -> String {
        var line = text
        if text.hasPrefix("["), text.hasSuffix("]") {
            line = SourceScan.splitTopLevel(String(text.dropFirst().dropLast()), separator: ",")
                .map { SourceScan.literal($0.trimmingCharacters(in: .whitespaces)) ?? $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        line = Sanitizer.clean(line.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }
}
