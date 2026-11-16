import Foundation

/// Feature flags, `flag:<key>`, and the code checking them (`symbol —checks_flag→ flag`, the
/// file outside any function). Found three ways in non-test code:
/// - SDK calls: LaunchDarkly `*Variation(Detail)`, OpenFeature/flagd `(get)?BooleanValue(…)` and
///   kin, Unleash `isEnabled`/`getVariant`, Split `getTreatment`, Statsig `checkGate`, GrowthBook
///   `isOn`/`getFeatureValue`: the first argument that's a known string is the key;
/// - wrappers named after flags or features (`isFeatureEnabled("new-checkout")`,
///   `useFlag("beta")`): a string literal argument;
/// - a constant named like a flag (`FlagNewCheckout`, `kFeatureBeta`, `betaFlag`) passed to any
///   call, which is how most wrappers are called (`IsEnabledForUser(ctx, project, flags.FlagX)`).
/// Keys come from literals or constants (Go package constants included). flagd JSON files
/// (`"flags": {…}`) define them: `flag —defined_in→ file`.
struct FeatureFlagExtractor: CodeExtractor {
    let name = "flags"
    var sharedKinds: [String] { ["flag"] }

    static let codeLanguages: Set<String> = ["go", "typescript", "javascript", "vue", "python", "swift", "kotlin", "java", "rust"]

    static func id(_ key: String) -> String { "flag:" + key }

    func accepts(path: String, language: String) -> Bool {
        (Self.codeLanguages.contains(language) && !SourceScan.isTest(path)) || language == "json"
    }

    static let sdkCall = SourceScan.regex(#"(?<![\w$])(\w*Variation(?:Detail)?|variation(?:Detail)?|(?:get)?(?:Boolean|String|Integer|Int|Float|Number|Object)Value(?:Details)?|get_(?:boolean|string|integer|float|object)_value(?:_details)?|isEnabled|IsEnabled|is_enabled|getVariant|GetVariant|get_variant|getTreatment|GetTreatment|get_treatment|checkGate|CheckGate|check_gate|getFeatureGate|isOn|IsOn|is_on|getFeatureValue|get_feature_value)\s*\("#)
    static let wrapperCall = SourceScan.regex(#"(?<![\w$])([A-Za-z_]\w*(?:[Ff]lag|[Ff]eature|[Tt]oggle)\w*)\s*\("#)
    static let flagConstant = SourceScan.regex(#"[(,]\s*((?:[A-Za-z_]\w*\.)?(?:Flag|FF|kFlag|kFeature|FeatureFlag)[A-Z_]\w*|(?:[A-Za-z_]\w*\.)?[a-zA-Z]\w*(?:Flag|FeatureFlag|Toggle))\s*(?=[,)])"#)
    /// Wrapper names that write, declare or parse rather than check.
    static let notChecks = #"^(?i)(set|add|register|define|create|update|delete|remove|new|parse|with|override|mock|fake|stub|reset|clear|list|all)"#

    func extract(_ file: ExtractionInput) -> Extraction {
        file.language == "json" ? Self.definitions(file) : Self.checks(file)
    }

    static func checks(_ file: ExtractionInput) -> Extraction {
        let lower = file.text.lowercased()
        let system = [("launchdarkly", "launchdarkly"), ("openfeature", "openfeature"), ("flagd", "flagd"), ("unleash", "unleash"), ("splitio", "split"),
                      ("@splitsoftware", "split"), ("statsig", "statsig"), ("growthbook", "growthbook"), ("configcat", "configcat")]
            .first { lower.contains($0.0) }?.1 ?? "custom"
        var found: [(key: String, line: Int)] = []
        func key(_ argument: String) -> String? {
            guard let value = file.evaluate(argument), value.range(of: #"^[A-Za-z][\w.:-]{1,99}$"#, options: .regularExpression) != nil else { return nil }
            return value
        }
        func skipped(_ offset: Int) -> Bool {
            let before = file.lineText(before: offset).trimmingCharacters(in: .whitespaces)
            return before.hasPrefix("//") || before.hasPrefix("#") || before.hasPrefix("*") || before.hasPrefix("/*")
        }
        for match in file.matches(sdkCall) {
            let open = match.range.location + match.range.length - 1
            guard !skipped(match.range.location), let arguments = file.arguments(at: open) else { continue }
            if let flag = arguments.ranges.lazy.compactMap({ key(file.text($0)) }).first { found.append((flag, file.line(at: match.range.location))) }
        }
        for match in file.matches(wrapperCall) {
            let name = file.text(match.range(at: 1))
            let open = match.range.location + match.range.length - 1
            guard name.range(of: notChecks, options: .regularExpression) == nil, !skipped(match.range.location),
                  let arguments = file.arguments(at: open) else { continue }
            let literal = arguments.ranges.lazy.map { file.text($0) }.first { SourceScan.literal($0) != nil }
            if let literal, let value = key(literal) { found.append((value, file.line(at: match.range.location))) }
        }
        for match in file.matches(flagConstant) {
            let line = file.lineText(before: match.range.location)
            guard !line.contains("Flags()"), !line.contains("flag."), !line.contains("pflag"), !skipped(match.range.location),
                  let value = key(file.text(match.range(at: 1))) else { continue }
            found.append((value, file.line(at: match.range.location)))
        }
        var result = Extraction()
        var seen = Set<String>()
        for (flag, line) in found {
            let caller = file.symbol(at: line) ?? file.fileID
            guard seen.insert(caller + "\n" + flag).inserted else { continue }
            if !result.nodes.contains(where: { $0.id == id(flag) }) { result.nodes.append(node(flag, system: system)) }
            result.edges.append(KnowledgeEdge(src: caller, dst: id(flag), kind: "checks_flag"))
        }
        return result
    }

    /// A definition's details go in the summary, which a check (with none) leaves alone.
    static func node(_ key: String, system: String, summary: String = "") -> KnowledgeNode {
        let label = ["launchdarkly": "LaunchDarkly", "openfeature": "OpenFeature", "flagd": "flagd", "unleash": "Unleash", "split": "Split",
                     "statsig": "Statsig", "growthbook": "GrowthBook", "configcat": "ConfigCat"][system]
        return KnowledgeNode(id: id(key), kind: "flag", name: key, qualified: key, language: system,
                             signature: "Feature flag " + key + (label.map { " (\($0))" } ?? ""), summary: summary, source: "code")
    }

    /// A flagd definition file: `{"flags": {"<key>": {"state": …, "variants": {…}, "defaultVariant": …}}}`.
    static func definitions(_ file: ExtractionInput) -> Extraction {
        guard file.text.contains("\"flags\""), file.text.contains("defaultVariant"), let data = file.text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flags = object["flags"] as? [String: Any] else { return Extraction() }
        var result = Extraction()
        for (key, value) in flags.sorted(by: { $0.key < $1.key }) {
            guard let flag = value as? [String: Any], key.range(of: #"^[A-Za-z][\w.:-]{1,99}$"#, options: .regularExpression) != nil else { continue }
            let state = (flag["state"] as? String).map { ", " + $0.lowercased() } ?? ""
            let variants = ((flag["variants"] as? [String: Any])?.keys.sorted()).map { ", variants " + $0.joined(separator: ", ") } ?? ""
            result.nodes.append(node(key, system: "flagd", summary: "Defined in " + file.path + state + variants + "."))
            result.edges.append(KnowledgeEdge(src: id(key), dst: file.fileID, kind: "defined_in"))
        }
        return result
    }
}
