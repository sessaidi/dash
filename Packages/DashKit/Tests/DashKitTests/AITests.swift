import DashKit
import Foundation
import Testing

struct AITests {
    private let review = AITask(
        id: "review", title: "Review", summary: "s", models: [.opus, .sonnet], efforts: [.high, .max], enabledByDefault: true,
        templates: [AITemplate(id: "title", title: "Title", defaultText: "[{{key}}] {{title}}", variables: ["key": "k", "title": "t"])])

    @Test func defaultsComeFromTheTask() {
        let settings = AISettings(tasks: [review])
        #expect(settings.model("review") == .opus)
        #expect(settings.effort("review") == .high)
        #expect(settings.isEnabled("review"))
        #expect(settings.render("review", "title", ["key": "A-1", "title": "Fix it"]) == "[A-1] Fix it")
    }

    @Test func choicesOverrideDefaultsWithinWhatTheTaskAllows() {
        var settings = AISettings(tasks: [review], choices: ["review": AITaskChoice(model: .sonnet, effort: .max, enabled: false,
                                                                                    templates: ["title": "{{ key }}: {{missing}}"])])
        #expect(settings.model("review") == .sonnet && settings.effort("review") == .max && !settings.isEnabled("review"))
        #expect(settings.render("review", "title", ["key": "A-1"]) == "A-1: ")
        // A model the task no longer allows falls back to its default.
        settings.choices["review"]?.model = .haiku
        #expect(settings.model("review") == .opus)
    }

    @Test func unknownTasksAreSafe() {
        let settings = AISettings(tasks: [])
        #expect(settings.isEnabled("nope") && settings.template("nope", "x").isEmpty && settings.effort("nope") == nil)
    }
}
