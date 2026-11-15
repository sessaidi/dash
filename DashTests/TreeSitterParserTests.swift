import Foundation
import Testing
@testable import Dash

/// Tree-sitter parsing per language (declarations, extents, containers, calls, supertypes,
/// imports), and the line-based parser as the fallback.
struct TreeSitterParserTests {
    @Test func parsesSwift() throws {
        let source = """
            import Foundation
            import struct Shared.Model

            @MainActor
            final class Billing: Service, @unchecked Sendable {
                init(rate: Double) { self.rate = rate }
                func renew(_ plan: Plan) -> Double {
                    let amount = charge(plan.price) // renew(again) in a comment
                    return store.save(amount)
                }
                struct Receipt: Codable {
                    func total() -> Int { sum() }
                }
            }

            extension Billing: Equatable {
                static func == (lhs: Billing, rhs: Billing) -> Bool { lhs.id == rhs.id }
            }

            protocol Service: AnyObject {
                func renew(_ plan: Plan) -> Double
            }
            """
        let result = try #require(TreeSitterParser.parse(source, language: "swift"))
        #expect(result.clean)
        let parsed = CodeParser.parse(source, language: "swift")
        #expect(parsed == result.parsed)
        #expect(parsed.imports == ["Foundation", "Shared.Model"])
        #expect(parsed.symbols.map(\.name) == ["Billing", "init", "renew", "Receipt", "total", "Billing", "==", "Service", "renew"])
        #expect(parsed.symbols.map(\.kind) == ["class", "method", "method", "struct", "method", "extension", "method", "protocol", "method"])
        #expect(parsed.symbols.map(\.container) == ["", "Billing", "Billing", "Billing", "Receipt", "", "Billing", "", "Service"])
        #expect(parsed.symbols.map(\.line) == [5, 6, 7, 11, 12, 16, 17, 20, 21])
        #expect(parsed.symbols.map(\.endLine) == [14, 6, 10, 13, 12, 18, 17, 22, 21])
        #expect(parsed.symbols[2].calls == ["charge", "save"])
        #expect(parsed.symbols[4].calls == ["sum"])
        #expect(parsed.symbols[0].inherits == ["Service", "Sendable"])
        #expect(parsed.symbols[3].inherits == ["Codable"] && parsed.symbols[5].inherits == ["Equatable"])
        #expect(parsed.symbols[7].inherits == ["AnyObject"])
        #expect(parsed.symbols[0].signature == "final class Billing: Service, @unchecked Sendable {")
    }

    @Test func parsesGo() throws {
        let source = """
            package billing

            import (
            \t"context"
            \tpay "example.com/acme/payments"
            )

            type Service struct {
            \t*Base
            \tio.Closer
            \trepo Repo
            }

            type Store interface {
            \tReader
            \tSave(ctx context.Context) error
            }

            func (s *Service) Renew(ctx context.Context) error {
            \tpay.Charge(ctx)
            \treturn s.repo.Save(ctx)
            }

            func New() *Service { return &Service{} }

            type ID = string
            """
        let result = try #require(TreeSitterParser.parse(source, language: "go"))
        #expect(result.clean)
        let parsed = result.parsed
        #expect(parsed.imports == ["context", "example.com/acme/payments"])
        #expect(parsed.symbols.map(\.name) == ["Service", "Store", "Renew", "New", "ID"])
        #expect(parsed.symbols.map(\.kind) == ["struct", "interface", "method", "function", "typealias"])
        #expect(parsed.symbols.map(\.container) == ["", "", "Service", "", ""])
        #expect(parsed.symbols.map(\.line) == [8, 14, 19, 24, 26])
        #expect(parsed.symbols.map(\.endLine) == [12, 17, 22, 24, 26])
        #expect(parsed.symbols[2].calls == ["Charge", "Save"])
        #expect(parsed.symbols[0].inherits == ["Base", "io.Closer"] && parsed.symbols[1].inherits == ["Reader"])
    }

    @Test func parsesTypeScript() throws {
        let source = """
            import { charge } from "./payments";
            const fs = require("fs");
            @Component({})
            export class Cart extends Base<Item> implements Totals, ns.Priced {
              total(): number {
                return charge(1) + this.tax.compute();
              }
              constructor() { super(); }
            }
            interface Totals extends Sum { f(): void }
            export const renew = async (id: string) => { await charge(2); };
            export function helper() { return new Receipt(); }
            """
        let result = try #require(TreeSitterParser.parse(source, language: "typescript"))
        #expect(result.clean)
        let parsed = result.parsed
        #expect(parsed.imports == ["./payments", "fs"])
        #expect(parsed.symbols.map(\.name) == ["Cart", "total", "Totals", "renew", "helper"])
        #expect(parsed.symbols.map(\.kind) == ["class", "method", "interface", "function", "function"])
        #expect(parsed.symbols.map(\.container) == ["", "Cart", "", "", ""])
        #expect(parsed.symbols.map(\.line) == [4, 5, 10, 11, 12])
        #expect(parsed.symbols[0].endLine == 9 && parsed.symbols[1].endLine == 7)
        #expect(parsed.symbols[1].calls == ["charge", "compute"])
        #expect(parsed.symbols[3].calls == ["charge"] && parsed.symbols[4].calls == ["Receipt"])
        #expect(parsed.symbols[0].inherits == ["Base", "Totals", "ns.Priced"] && parsed.symbols[2].inherits == ["Sum"])
    }

    @Test func parsesJSXWithTheTSXGrammar() throws {
        let source = "import React from 'react';\nexport function App() {\n  return <div onClick={() => save()}>hi</div>;\n}\n"
        for language in ["typescript", "javascript"] {
            let result = try #require(TreeSitterParser.parse(source, language: language))
            #expect(result.clean)
            #expect(result.parsed.symbols.map(\.name) == ["App"] && result.parsed.symbols[0].endLine == 4)
            #expect(result.parsed.symbols[0].calls == ["save"] && result.parsed.imports == ["react"])
        }
    }

    @Test func parsesPython() throws {
        let source = """
            import os, json as j
            from .billing import charge

            class Cart(Base, mixins.Priced, metaclass=Meta):
                @property
                def total(self):
                    return charge(self.items).round()

            def helper():
                pass
            """
        let result = try #require(TreeSitterParser.parse(source, language: "python"))
        #expect(result.clean)
        let parsed = result.parsed
        #expect(parsed.imports == [".billing", "json", "os"])
        #expect(parsed.symbols.map(\.name) == ["Cart", "total", "helper"])
        #expect(parsed.symbols.map(\.kind) == ["class", "method", "function"])
        #expect(parsed.symbols.map(\.container) == ["", "Cart", ""])
        #expect(parsed.symbols.map(\.line) == [4, 6, 9] && parsed.symbols.map(\.endLine) == [7, 7, 10])
        #expect(parsed.symbols[1].calls == ["charge", "round"])
        #expect(parsed.symbols[0].inherits == ["Base", "mixins.Priced"])
    }

    // MARK: Fallback

    @Test func otherLanguagesUseTheLineParser() {
        #expect(TreeSitterParser.parse("fn main() {}", language: "rust") == nil)
        let rust = CodeParser.parse("struct Cart {}\n\nimpl fmt::Display for Cart {\n    fn fmt(&self) { write(f) }\n}\n", language: "rust")
        #expect(rust == CodeParser.parseLines("struct Cart {}\n\nimpl fmt::Display for Cart {\n    fn fmt(&self) { write(f) }\n}\n", language: "rust"))
        #expect(rust.symbols.map(\.name) == ["Cart", "Cart", "fmt"] && rust.symbols[1].inherits == ["fmt::Display"])

        let kotlin = CodeParser.parse("class Cart(val id: Int) : Base(id), Priced {\n}\n", language: "kotlin")
        #expect(kotlin.symbols[0].inherits == ["Base", "Priced"])
        let java = CodeParser.parse("public class Cart<T> extends Base<T> implements Priced, Totals {\n}\n", language: "java")
        #expect(java.symbols[0].inherits == ["Base", "Priced", "Totals"])
    }

    @Test func lineParserReadsSupertypes() {
        let swift = CodeParser.parseLines("public final class A<T: Equatable>: B, @unchecked Sendable where T: Hashable {\n}\n", language: "swift")
        #expect(swift.symbols[0].inherits == ["B", "Sendable"])
        let ts = CodeParser.parseLines("export class Cart extends Base<Item> implements Totals, ns.Priced {\n}\n", language: "typescript")
        #expect(ts.symbols[0].inherits == ["Base", "Totals", "ns.Priced"])
        let python = CodeParser.parseLines("class Cart(Base, metaclass=Meta):\n    pass\n", language: "python")
        #expect(python.symbols[0].inherits == ["Base"])
    }

    /// A file that doesn't parse cleanly still gives its declarations, from whichever parser
    /// finds more of them.
    @Test func brokenFilesKeepTheirDeclarations() {
        let source = "struct A {\n    func one() { two( }\n    func two() {}\n}\n\nfunc three() {}\n"
        let parsed = CodeParser.parse(source, language: "swift")
        #expect(Set(parsed.symbols.map(\.name)).isSuperset(of: ["A", "one", "three"]))
    }
}
