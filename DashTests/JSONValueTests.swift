import DashKit
import DashKitUI
import Foundation
import Testing
@testable import Dash

struct JSONValueTests {
    @Test func roundTripsAndKeepsIntegersIntegral() throws {
        let value: JSONValue = ["a": 1, "b": 1.5, "c": [true, nil, "x"]]
        #expect(value.jsonString() == #"{"a":1,"b":1.5,"c":[true,null,"x"]}"#)
        #expect(try JSONValue.parse(value.jsonString()) == value)
    }

    @Test func distinguishesBoolFromNumber() throws {
        #expect(try JSONValue.parse("[true, 1]") == [true, 1])
    }

    @Test func mergeIsShallow() {
        let base: JSONValue = ["a": 1, "b": ["x": 1]]
        #expect(base.merging(["b": ["y": 2], "c": 3]) == ["a": 1, "b": ["y": 2], "c": 3])
    }
}
