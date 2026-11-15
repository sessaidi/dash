import Foundation

/// The SDK version plugins are built against. Plugins declare the minimum they need.
public enum DashKitInfo {
    public static let version = "2.2.0"

    /// The major version: a plugin must be built for this one (a new major breaks the ABI).
    public static var major: Int { Int(version.split(separator: ".").first ?? "") ?? 0 }

    /// Why a plugin needing DashKit `minimum` can't run in this Dash, or nil when it can: it must
    /// target this major version, at this minor or older.
    public static func incompatibility(minimum: String?) -> String? {
        guard let minimum else { return "Built for an older DashKit; update it from the Marketplace." }
        let needed = Int(minimum.split(separator: ".").first ?? "") ?? 0
        if needed < major { return "Built for DashKit \(minimum); this Dash has \(version). Update it from the Marketplace." }
        if ExtensionMetadata.compare(version, minimum) == .orderedAscending { return "Needs DashKit \(minimum); this Dash has \(version). Update Dash." }
        return nil
    }
}

/// Extensions come in two layers:
/// - an **integration** owns an account and its connection (GitHub: token, API URL, watched repos);
/// - a **feature** builds on one or more integrations (Pull Requests requires `github`).
public enum ExtensionLayer: String, Codable, Sendable {
    case integration, feature
}

/// Who owns an extension: a person, team or company.
public struct ExtensionAuthor: Codable, Hashable, Sendable {
    public var name: String
    public var url: String?
    public var email: String?

    public init(name: String, url: String? = nil, email: String? = nil) {
        self.name = name
        self.url = url
        self.email = email
    }

    public static let dash = ExtensionAuthor(name: "Dash")
}

public enum ExtensionCategory: String, Codable, Sendable, CaseIterable {
    case sourceControl = "source-control"
    case projectManagement = "project-management"
    case cloud
    case communication
    case monitoring
    case productivity
    case ai
    case other

    public var title: String {
        switch self {
        case .sourceControl: "Source control"
        case .projectManagement: "Project management"
        case .cloud: "Cloud"
        case .communication: "Communication"
        case .monitoring: "Monitoring"
        case .productivity: "Productivity"
        case .ai: "AI"
        case .other: "Other"
        }
    }
}

/// Everything shown about an extension in Settings, the Extensions window and the marketplace.
public struct ExtensionMetadata: Codable, Hashable, Sendable {
    /// Semantic version, "1.2.0".
    public var version: String
    public var author: ExtensionAuthor
    /// One sentence.
    public var summary: String
    public var category: ExtensionCategory
    public var tags: [String]
    public var homepage: String?
    public var repository: String?
    public var documentation: String?
    /// SPDX identifier, "MIT".
    public var license: String?
    /// Oldest DashKit this extension works with.
    public var minimumDashKit: String?

    public init(
        version: String = "1.0.0", author: ExtensionAuthor = .dash, summary: String = "", category: ExtensionCategory = .other,
        tags: [String] = [], homepage: String? = nil, repository: String? = nil, documentation: String? = nil,
        license: String? = nil, minimumDashKit: String? = nil
    ) {
        self.version = version
        self.author = author
        self.summary = summary
        self.category = category
        self.tags = tags
        self.homepage = homepage
        self.repository = repository
        self.documentation = documentation
        self.license = license
        self.minimumDashKit = minimumDashKit
    }

    /// True when this targets this DashKit's major version, at this minor or older (or declares none: built in).
    public var isCompatible: Bool { minimumDashKit.map { DashKitInfo.incompatibility(minimum: $0) == nil } ?? true }

    /// Compares dotted numeric versions ("1.10.0" > "1.9.3").
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
