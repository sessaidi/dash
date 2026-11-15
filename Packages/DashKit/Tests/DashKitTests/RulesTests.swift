import Foundation
import Testing
@testable import DashKit

/// Rules as a list: declared fluently or read from Markdown, edited, sent to Dashii.
struct RulesTests {
    @Test func builderAndInstructions() {
        let showReviews = true
        let set = RuleSet {
            Rule.note("review_verdict comes from Dash's own review.")
            Rule.never("Post to GitHub.")
            if showReviews { Rule.always("Cite PRs as owner/name#123.") }
            Rule.prefer("github_get_pr over the API.").disabled()
        }
        #expect(set.rules.map(\.kind) == [.note, .never, .always, .prefer])
        #expect(set.instructions == "- review_verdict comes from Dash's own review.\n- Never: Post to GitHub.\n- Always: Cite PRs as owner/name#123.")
    }

    @Test func markdownRoundTripKeepsTurnedOffRules() {
        let text = """
            # Rules
            - Never: post reviews to GitHub;
              creating a PR is the user's.
            - [off] Prefer: the Datadog tools.
            * Cite PRs as owner/name#123.
            """
        let set = RuleSet.parse(text)
        #expect(set.rules.map(\.kind) == [.never, .prefer, .note])
        #expect(set.rules[0].text == "post reviews to GitHub; creating a PR is the user's.")
        #expect(set.rules[1].enabled == false)
        let again = RuleSet.parse(set.markdown)
        #expect(again.rules.map(\.text) == set.rules.map(\.text) && again.rules.map(\.enabled) == [true, false, true])
        #expect(set.instructions?.contains("Datadog") == false)
    }
}
