import Foundation

/// Message topics, queues and subjects (`topic:<system>:<name>`, system kafka, pubsub, sqs, sns,
/// nats or amqp) and the code publishing to or consuming them, in Go, TypeScript/JavaScript and
/// Python, for each system's common clients; plus their declarations in Terraform and in
/// Kubernetes manifests (Strimzi `KafkaTopic`, Config Connector `PubSubTopic`/`PubSubSubscription`).
/// The same name in two repositories is the same node, so a publisher meets its consumers. A
/// name only an environment variable gives is `$VARIABLE`. Pub/Sub subscriptions are topic nodes
/// too ("Pub/Sub subscription …"), and `consumes` the topic they're declared on.
struct MessagingExtractor: CodeExtractor {
    let name = "messaging"
    var sharedKinds: [String] { ["topic"] }

    func accepts(path: String, language: String) -> Bool {
        ["go", "typescript", "javascript", "python", "terraform", "yaml"].contains(language) && !SourceScan.isTest(path)
    }

    struct Use: Equatable {
        var system: String
        var name: String
        var fromEnvironment = false
        var subscription = false
        var consumes: Bool
        var line: Int
    }

    static func id(_ system: String, _ name: String) -> String { "topic:\(system):\(name)" }

    private static let labels = ["kafka": "Kafka topic", "pubsub": "Pub/Sub topic", "sqs": "SQS queue", "sns": "SNS topic",
                                 "nats": "NATS subject", "amqp": "RabbitMQ exchange or queue"]

    static func node(system: String, name: String, fromEnvironment: Bool = false, subscription: Bool = false, line: Int = 0, path: String = "") -> KnowledgeNode {
        let label = subscription ? "Pub/Sub subscription" : labels[system] ?? system
        let shown = fromEnvironment ? "$" + name : name
        return KnowledgeNode(id: id(system, shown), kind: "topic", name: shown, qualified: system + ":" + shown, path: path, line: line, language: system,
                             signature: fromEnvironment ? "\(label) named by the environment variable \(name)" : "\(label) \(name)", source: "code")
    }

    func extract(_ file: ExtractionInput) -> Extraction {
        switch file.language {
        case "terraform": return Self.terraform(file)
        case "yaml": return Self.manifests(file)
        case "go": return Self.extraction(GoMessaging.find(file), in: file)
        case "python": return Self.extraction(PythonMessaging.find(file), in: file)
        default: return Self.extraction(ScriptMessaging.find(file), in: file)
        }
    }

    static func extraction(_ uses: [Use], in file: ExtractionInput) -> Extraction {
        var result = Extraction()
        var seen = Set<String>()
        for use in uses {
            let node = node(system: use.system, name: use.name, fromEnvironment: use.fromEnvironment, subscription: use.subscription)
            if seen.insert(node.id).inserted { result.nodes.append(node) }
            let edge = KnowledgeEdge(src: file.symbol(at: use.line) ?? file.fileID, dst: node.id, kind: use.consumes ? "consumes" : "publishes")
            if !result.edges.contains(edge) { result.edges.append(edge) }
        }
        return result
    }

    /// A name as the system knows it: Pub/Sub paths, SQS queue URLs and ARNs reduced to the name.
    static func normalize(_ system: String, _ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch system {
        case "pubsub":
            if name.hasPrefix("projects/") { name = String(name.split(separator: "/").last ?? "") }
        case "sqs", "sns":
            if name.hasPrefix("arn:") { name = String(name.split(separator: ":").last ?? "") }
            else if name.contains("://") { name = String(name.split(separator: "/").last ?? "") }
        default:
            break
        }
        guard !name.isEmpty, name != "{}", name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, name.count <= 200 else { return nil }
        return name
    }

    // MARK: Declarations

    /// Terraform resources declaring topics, subscriptions and queues.
    static func terraform(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        guard file.text.contains("pubsub") || file.text.contains("sqs") || file.text.contains("sns") || file.text.contains("kafka") else { return result }
        let systems = ["google_pubsub_topic": "pubsub", "google_pubsub_subscription": "pubsub", "aws_sqs_queue": "sqs", "aws_sns_topic": "sns",
                       "kafka_topic": "kafka", "confluent_kafka_topic": "kafka"]
        var topicNames: [String: String] = [:]
        var subscriptions: [(node: KnowledgeNode, topic: String)] = []
        for match in file.matches(SourceScan.regex(#"(?m)^\s*resource\s+"(\w+)"\s+"([\w-]+)"\s*\{"#)) {
            let type = file.text(match.range(at: 1))
            guard let system = systems[type], let close = file.closing(at: match.range.location + match.range.length - 1) else { continue }
            let open = match.range.location + match.range.length
            let body = file.text(NSRange(location: open, length: close - open))
            guard let raw = SourceScan.matches(#"(?m)^\s*(?:name|topic_name)\s*=\s*"([^"\n]+)""#, in: body).first?[1],
                  let name = normalize(system, raw.replacingOccurrences(of: #"\$\{[^}]*\}"#, with: "{}", options: .regularExpression)) else { continue }
            let subscription = type == "google_pubsub_subscription"
            let node = node(system: system, name: name, subscription: subscription, line: file.line(at: match.range.location), path: file.path)
            result.nodes.append(node)
            result.edges.append(KnowledgeEdge(src: node.id, dst: file.fileID, kind: "defined_in"))
            if subscription {
                if let topic = SourceScan.matches(#"(?m)^\s*topic\s*=\s*(\S+)"#, in: body).first?[1] { subscriptions.append((node, topic)) }
            } else if type == "google_pubsub_topic" {
                topicNames[file.text(match.range(at: 2))] = name
            }
        }
        for (subscription, reference) in subscriptions {
            let name = SourceScan.matches(#"^google_pubsub_topic\.([\w-]+)\.(?:name|id)$"#, in: reference).first.flatMap { topicNames[$0[1]] }
                ?? SourceScan.literal(reference).flatMap { normalize("pubsub", $0) }
            if let name { result.edges.append(KnowledgeEdge(src: subscription.id, dst: id("pubsub", name), kind: "consumes")) }
        }
        return result
    }

    /// Kubernetes custom resources: Strimzi `KafkaTopic`, Config Connector `PubSubTopic` and
    /// `PubSubSubscription` (which consumes its `topicRef`).
    static func manifests(_ file: ExtractionInput) -> Extraction {
        var result = Extraction()
        guard file.text.contains("KafkaTopic") || file.text.contains("PubSub") else { return result }
        var offset = 0
        for document in file.text.components(separatedBy: "\n---") {
            defer { offset += (document as NSString).length + 4 }
            guard let kind = SourceScan.matches(#"(?m)^kind:\s*["']?(KafkaTopic|PubSubTopic|PubSubSubscription)["']?\s*$"#, in: document).first?[1],
                  let metadata = SourceScan.matches(#"(?m)^metadata:[ \t]*\n(?:[ \t][^\n]*\n)*?[ \t]+name:[ \t]*["']?([\w.-]+)"#, in: document).first?[1] else { continue }
            let line = file.line(at: offset + 1)
            switch kind {
            case "KafkaTopic":
                let name = SourceScan.matches(#"(?m)^[ \t]+topicName:[ \t]*["']?([\w.-]+)"#, in: document).first?[1] ?? metadata
                let node = node(system: "kafka", name: name, line: line, path: file.path)
                result.nodes.append(node)
                result.edges.append(KnowledgeEdge(src: node.id, dst: file.fileID, kind: "defined_in"))
            default:
                let node = node(system: "pubsub", name: metadata, subscription: kind == "PubSubSubscription", line: line, path: file.path)
                result.nodes.append(node)
                result.edges.append(KnowledgeEdge(src: node.id, dst: file.fileID, kind: "defined_in"))
                if kind == "PubSubSubscription", let topic = SourceScan.matches(#"(?m)^[ \t]+topicRef:[ \t]*\n[ \t]+name:[ \t]*["']?([\w.-]+)"#, in: document).first?[1] {
                    result.edges.append(KnowledgeEdge(src: node.id, dst: id("pubsub", topic), kind: "consumes"))
                }
            }
        }
        return result
    }
}

extension ExtractionInput {
    /// A topic, queue or subject named by an expression: a literal or constant, a variable
    /// assigned earlier, a default (`os.getenv("T", "events")`, `process.env.T ?? 'events'`, a Go
    /// field's `envDefault`), else the environment variable alone.
    func messagingName(_ raw: String, system: String, at offset: Int, depth: Int = 0) -> (name: String, fromEnvironment: Bool)? {
        var expression = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = expression.first, "&*".contains(first) { expression.removeFirst() }
        if let call = SourceScan.call(expression), ["aws.String", "String", "str"].contains(call.callee), call.arguments.count == 1 {
            return messagingName(call.arguments[0], system: system, at: offset, depth: depth)
        }
        // `a || 'x'`, `a ?? 'x'`, `a or "x"`, `os.getenv("A", "x")`: the literal fallback names it.
        let alternatives = expression.components(separatedBy: " ?? ").flatMap { $0.components(separatedBy: " || ") }.flatMap { $0.components(separatedBy: " or ") }
        if alternatives.count > 1, let fallback = alternatives.dropFirst().compactMap({ SourceScan.literal($0.trimmingCharacters(in: .whitespaces)) }).first,
           let name = MessagingExtractor.normalize(system, fallback) {
            return (name, false)
        }
        if let call = SourceScan.call(expression), ["os.getenv", "os.environ.get", "getenv"].contains(call.callee), call.arguments.count == 2,
           let fallback = SourceScan.literal(call.arguments[1].trimmingCharacters(in: .whitespaces)), let name = MessagingExtractor.normalize(system, fallback) {
            return (name, false)
        }
        if let variable = Self.environmentVariable(alternatives[0].trimmingCharacters(in: .whitespaces)) { return (variable, true) }
        if let value = evaluate(expression), let name = MessagingExtractor.normalize(system, value) { return (name, false) }
        guard depth < 3 else { return nil }
        if expression.range(of: #"^[A-Za-z_$][\w$]*$"#, options: .regularExpression) != nil, let assigned = assignment(of: expression, before: offset) {
            return messagingName(assigned, system: system, at: offset, depth: depth + 1)
        }
        if language == "go", expression.contains("."), let field = expression.split(separator: ".").last.map(String.init),
           field.range(of: #"^[A-Z]\w*$"#, options: .regularExpression) != nil {
            if let value = context.goEnvironmentDefault(field), let name = MessagingExtractor.normalize(system, value) { return (name, false) }
            if let variable = context.goEnvironmentFields()[field] { return (variable, true) }
        }
        return nil
    }

    /// Calls matching `pattern` (which ends at the call's "("): the match and the arguments.
    func messagingCalls(_ pattern: String) -> [(match: NSTextCheckingResult, arguments: [String])] {
        matches(SourceScan.regex(pattern)).compactMap { match in
            arguments(at: match.range.location + match.range.length - 1).map { (match, $0.ranges.map(text)) }
        }
    }

    /// The value of `field` in the composite literal or object whose "{" is at `open`
    /// (`Topic: x` in Go, `topic: x` in JS).
    func literalField(_ field: String, at open: Int) -> String? {
        guard let entries = arguments(at: open, limit: 20_000) else { return nil }
        for range in entries.ranges {
            let entry = text(range)
            if let match = SourceScan.matches(#"^['"]?"# + field + #"['"]?\s*:\s*([\s\S]+)$"#, in: entry).first { return match[1] }
        }
        return nil
    }
}

/// Go clients: Pub/Sub, kafka-go, sarama, confluent-kafka-go, AWS SQS/SNS, NATS and RabbitMQ.
enum GoMessaging {
    static func find(_ file: ExtractionInput) -> [MessagingExtractor.Use] {
        let text = file.text
        var uses: [MessagingExtractor.Use] = []
        func add(_ system: String, _ expression: String, at offset: Int, consumes: Bool, subscription: Bool = false) {
            guard let name = file.messagingName(expression, system: system, at: offset) else { return }
            uses.append(.init(system: system, name: name.name, fromEnvironment: name.fromEnvironment, subscription: subscription, consumes: consumes, line: file.line(at: offset)))
        }
        func literal(_ type: String, field: String, system: String, consumes: Bool) {
            for match in file.matches(SourceScan.regex(#"\b"# + NSRegularExpression.escapedPattern(for: type) + #"\s*\{"#)) {
                let open = match.range.location + match.range.length - 1
                if let value = file.literalField(field, at: open) { add(system, value, at: match.range.location, consumes: consumes) }
            }
        }
        if text.contains("cloud.google.com/go/pubsub") {
            for call in file.messagingCalls(#"\.(Topic|TopicInProject|Publisher|Subscription|SubscriptionInProject|Subscriber)\("#) {
                guard let first = call.arguments.first else { continue }
                let method = file.text(call.match.range(at: 1))
                let subscription = method.hasPrefix("Subscri")
                add("pubsub", first, at: call.match.range.location, consumes: subscription, subscription: subscription)
            }
        }
        if text.contains("segmentio/kafka-go") {
            for type in ["kafka.Writer", "kafka.WriterConfig", "kafka.Message"] { literal(type, field: "Topic", system: "kafka", consumes: false) }
            literal("kafka.ReaderConfig", field: "Topic", system: "kafka", consumes: true)
            for match in file.matches(SourceScan.regex(#"\bGroupTopics\s*:\s*\[\]string\s*\{"#)) {
                for topic in file.arguments(at: match.range.location + match.range.length - 1)?.ranges ?? [] { add("kafka", file.text(topic), at: match.range.location, consumes: true) }
            }
        }
        if text.contains("/sarama") {
            literal("sarama.ProducerMessage", field: "Topic", system: "kafka", consumes: false)
            for call in file.messagingCalls(#"\.ConsumePartition\("#) { if let first = call.arguments.first { add("kafka", first, at: call.match.range.location, consumes: true) } }
        }
        if text.contains("confluent-kafka-go") {
            literal("kafka.TopicPartition", field: "Topic", system: "kafka", consumes: false)
            for call in file.messagingCalls(#"\.Subscribe\("#) { if let first = call.arguments.first { add("kafka", first, at: call.match.range.location, consumes: true) } }
        }
        if text.contains("/sarama") || text.contains("confluent-kafka-go") {
            for match in file.matches(SourceScan.regex(#"\.(?:Consume|SubscribeTopics)\([^)]*?\[\]string\s*\{"#)) {
                for topic in file.arguments(at: match.range.location + match.range.length - 1)?.ranges ?? [] { add("kafka", file.text(topic), at: match.range.location, consumes: true) }
            }
        }
        if text.contains("service/sqs") {
            for type in ["sqs.SendMessageInput", "sqs.SendMessageBatchInput"] { literal(type, field: "QueueUrl", system: "sqs", consumes: false) }
            literal("sqs.ReceiveMessageInput", field: "QueueUrl", system: "sqs", consumes: true)
        }
        if text.contains("service/sns") { literal("sns.PublishInput", field: "TopicArn", system: "sns", consumes: false) }
        if text.contains("nats-io/nats.go") {
            for call in file.messagingCalls(#"\.(Publish|PublishMsg|Request|Subscribe|SubscribeSync|QueueSubscribe|ChanSubscribe|PullSubscribe)\("#) {
                guard let first = call.arguments.first, SourceScan.literal(first) != nil || !first.contains("(") else { continue }
                add("nats", first, at: call.match.range.location, consumes: !["Publish", "PublishMsg", "Request"].contains(file.text(call.match.range(at: 1))))
            }
        }
        if text.contains("amqp091-go") || text.contains("streadway/amqp") {
            for call in file.messagingCalls(#"\.(Publish|PublishWithContext)\("#) {
                let arguments = file.text(call.match.range(at: 1)) == "Publish" ? call.arguments : Array(call.arguments.dropFirst())
                guard arguments.count >= 2 else { continue }
                let exchange = file.messagingName(arguments[0], system: "amqp", at: call.match.range.location)
                add("amqp", exchange == nil ? arguments[1] : arguments[0], at: call.match.range.location, consumes: false)
            }
            for call in file.messagingCalls(#"\.Consume\("#) { if let first = call.arguments.first { add("amqp", first, at: call.match.range.location, consumes: true) } }
        }
        return uses
    }
}

/// TypeScript/JavaScript clients: kafkajs, @google-cloud/pubsub, AWS SDK v2/v3, amqplib, NATS.
enum ScriptMessaging {
    static func find(_ file: ExtractionInput) -> [MessagingExtractor.Use] {
        let text = file.text
        var uses: [MessagingExtractor.Use] = []
        func add(_ system: String, _ expression: String, at offset: Int, consumes: Bool, subscription: Bool = false) {
            guard let name = file.messagingName(expression, system: system, at: offset) else { return }
            uses.append(.init(system: system, name: name.name, fromEnvironment: name.fromEnvironment, subscription: subscription, consumes: consumes, line: file.line(at: offset)))
        }
        func object(_ pattern: String, field: String, system: String, consumes: Bool) {
            for match in file.matches(SourceScan.regex(pattern)) {
                if let value = file.literalField(field, at: match.range.location + match.range.length - 1) { add(system, value, at: match.range.location, consumes: consumes) }
            }
        }
        if text.contains("kafkajs") {
            object(#"\.send\(\s*\{"#, field: "topic", system: "kafka", consumes: false)
            object(#"\.subscribe\(\s*\{"#, field: "topic", system: "kafka", consumes: true)
            for match in file.matches(SourceScan.regex(#"\.subscribe\(\s*\{[^}]*?\btopics\s*:\s*\["#)) {
                for topic in file.arguments(at: match.range.location + match.range.length - 1)?.ranges ?? [] { add("kafka", file.text(topic), at: match.range.location, consumes: true) }
            }
        }
        if text.contains("@google-cloud/pubsub") {
            for call in file.messagingCalls(#"\.(topic|subscription)\("#) {
                guard let first = call.arguments.first else { continue }
                let subscription = file.text(call.match.range(at: 1)) == "subscription"
                add("pubsub", first, at: call.match.range.location, consumes: subscription, subscription: subscription)
            }
        }
        if text.contains("client-sqs") || text.contains("aws-sdk") {
            object(#"\bnew\s+(?:SendMessageCommand|SendMessageBatchCommand)\(\s*\{"#, field: "QueueUrl", system: "sqs", consumes: false)
            object(#"\bnew\s+ReceiveMessageCommand\(\s*\{"#, field: "QueueUrl", system: "sqs", consumes: true)
            object(#"\.(?:sendMessage|sendMessageBatch)\(\s*\{"#, field: "QueueUrl", system: "sqs", consumes: false)
            object(#"\.receiveMessage\(\s*\{"#, field: "QueueUrl", system: "sqs", consumes: true)
        }
        if text.contains("client-sns") || text.contains("aws-sdk") {
            object(#"\bnew\s+PublishCommand\(\s*\{"#, field: "TopicArn", system: "sns", consumes: false)
            object(#"\.publish\(\s*\{"#, field: "TopicArn", system: "sns", consumes: false)
        }
        if text.contains("amqplib") {
            for call in file.messagingCalls(#"\.(sendToQueue|publish|consume)\("#) {
                guard let first = call.arguments.first else { continue }
                let method = file.text(call.match.range(at: 1))
                let target = method == "publish" && SourceScan.literal(first) == "" && call.arguments.count > 1 ? call.arguments[1] : first
                add("amqp", target, at: call.match.range.location, consumes: method == "consume")
            }
        }
        if text.range(of: #"from\s+['"]nats(?:\.ws)?['"]|require\(\s*['"]nats['"]\s*\)"#, options: .regularExpression) != nil {
            for call in file.messagingCalls(#"\.(publish|request|subscribe)\("#) {
                guard let first = call.arguments.first else { continue }
                add("nats", first, at: call.match.range.location, consumes: file.text(call.match.range(at: 1)) == "subscribe")
            }
        }
        return uses
    }
}

/// Python clients: kafka-python, confluent-kafka, google-cloud-pubsub, boto3 SQS/SNS, nats.
enum PythonMessaging {
    static func find(_ file: ExtractionInput) -> [MessagingExtractor.Use] {
        let text = file.text
        var uses: [MessagingExtractor.Use] = []
        func add(_ system: String, _ expression: String, at offset: Int, consumes: Bool, subscription: Bool = false) {
            guard let name = file.messagingName(expression, system: system, at: offset) else { return }
            uses.append(.init(system: system, name: name.name, fromEnvironment: name.fromEnvironment, subscription: subscription, consumes: consumes, line: file.line(at: offset)))
        }
        func positional(_ arguments: [String]) -> [String] { arguments.filter { !$0.contains("=") || $0.hasPrefix("\"") || $0.hasPrefix("'") } }
        if text.contains("kafka") {
            for call in file.messagingCalls(#"\bKafkaConsumer\("#) {
                for topic in positional(call.arguments) { add("kafka", topic, at: call.match.range.location, consumes: true) }
            }
            for call in file.messagingCalls(#"(?:\b\w*[pP]roducer\w*\.send|\.produce)\("#) {
                guard let topic = SourceScan.keyword("topic", in: call.arguments) ?? positional(call.arguments).first else { continue }
                add("kafka", topic, at: call.match.range.location, consumes: false)
            }
            for match in file.matches(SourceScan.regex(#"\.subscribe\(\s*(?:topics\s*=\s*)?\["#)) {
                for topic in file.arguments(at: match.range.location + match.range.length - 1)?.ranges ?? [] { add("kafka", file.text(topic), at: match.range.location, consumes: true) }
            }
        }
        if text.contains("pubsub") {
            for call in file.messagingCalls(#"\.(topic_path|subscription_path)\("#) {
                guard call.arguments.count >= 2 else { continue }
                let subscription = file.text(call.match.range(at: 1)) == "subscription_path"
                add("pubsub", call.arguments[1], at: call.match.range.location, consumes: subscription, subscription: subscription)
            }
        }
        if text.contains("boto3") {
            for call in file.messagingCalls(#"\.(send_message|send_message_batch|receive_message)\("#) {
                if let queue = SourceScan.keyword("QueueUrl", in: call.arguments) {
                    add("sqs", queue, at: call.match.range.location, consumes: file.text(call.match.range(at: 1)) == "receive_message")
                }
            }
            for call in file.messagingCalls(#"\.publish\("#) {
                if let topic = SourceScan.keyword("TopicArn", in: call.arguments) { add("sns", topic, at: call.match.range.location, consumes: false) }
            }
        }
        if text.range(of: #"(?m)^\s*(?:import nats|from nats)"#, options: .regularExpression) != nil {
            for call in file.messagingCalls(#"\.(publish|request|subscribe)\("#) {
                guard let first = positional(call.arguments).first else { continue }
                add("nats", first, at: call.match.range.location, consumes: file.text(call.match.range(at: 1)) == "subscribe")
            }
        }
        return uses
    }
}
