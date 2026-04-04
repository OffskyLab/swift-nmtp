import Testing
import Foundation
@testable import NMTP

@Suite("Argument Tests")
struct ArgumentTests {

    @Test("Argument wrap/unwrap round-trip with String")
    func argumentRoundTripString() throws {
        let arg = try Argument.wrap(key: "name", value: "Alice")
        let recovered = try arg.unwrap(as: String.self)
        #expect(recovered == "Alice")
        #expect(arg.key == "name")
    }

    @Test("Argument wrap/unwrap round-trip with Int")
    func argumentRoundTripInt() throws {
        let arg = try Argument.wrap(key: "count", value: 42)
        let recovered = try arg.unwrap(as: Int.self)
        #expect(recovered == 42)
        #expect(arg.key == "count")
    }

    @Test("[Argument].toEncoded() and [EncodedArgument].toArguments() round-trip")
    func argumentArrayRoundTrip() throws {
        let args: [Argument] = [
            try Argument.wrap(key: "a", value: "hello"),
            try Argument.wrap(key: "b", value: 99),
        ]
        let encoded = args.toEncoded()
        #expect(encoded.count == 2)
        #expect(encoded[0].key == "a")
        #expect(encoded[1].key == "b")

        let decoded = encoded.toArguments()
        #expect(decoded.count == 2)
        let str = try decoded[0].unwrap(as: String.self)
        let num = try decoded[1].unwrap(as: Int.self)
        #expect(str == "hello")
        #expect(num == 99)
    }

    @Test("ArgumentValue string literal")
    func argumentValueStringLiteral() {
        let v: ArgumentValue = "hello"
        if case .string(let s) = v {
            #expect(s == "hello")
        } else {
            Issue.record("Expected .string case")
        }
    }

    @Test("ArgumentValue int literal")
    func argumentValueIntLiteral() {
        let v: ArgumentValue = 42
        if case .int(let n) = v {
            #expect(n == 42)
        } else {
            Issue.record("Expected .int case")
        }
    }

    @Test("ArgumentValue double literal")
    func argumentValueDoubleLiteral() {
        let v: ArgumentValue = 3.14
        if case .double(let d) = v {
            #expect(d == 3.14)
        } else {
            Issue.record("Expected .double case")
        }
    }

    @Test("ArgumentValue bool literal")
    func argumentValueBoolLiteral() {
        let v: ArgumentValue = true
        if case .bool(let b) = v {
            #expect(b == true)
        } else {
            Issue.record("Expected .bool case")
        }
    }

    @Test("ArgumentValue array literal")
    func argumentValueArrayLiteral() {
        let v: ArgumentValue = ["a", "b", "c"]
        if case .array(let arr) = v {
            #expect(arr.count == 3)
        } else {
            Issue.record("Expected .array case")
        }
    }

    @Test("ArgumentValue is Encodable")
    func argumentValueEncodable() throws {
        let arg = try Argument.wrap(key: "val", value: ArgumentValue.string("test"))
        let recovered = try arg.unwrap(as: String.self)
        #expect(recovered == "test")
    }
}
