import XCTest

@testable import RillCore

@MainActor final class SchemaTests: XCTestCase {
    func validate(_ instance: String, _ schema: String) throws -> SchemaValidation {
        try JSONSchema.validate(instance: Data(instance.utf8), schema: Data(schema.utf8))
    }
    func testExactNumbersStringsAndCombinations() throws {
        XCTAssertTrue(
            try validate(
                "9007199254740993",
                ##"{"type":"integer","minimum":9007199254740993,"maximum":9007199254740993}"##
            ).valid)
        XCTAssertFalse(try validate("9007199254740992", ##"{"minimum":9007199254740993}"##).valid)
        XCTAssertFalse(try validate("0.10000000000000001", ##"{"maximum":0.1}"##).valid)
        XCTAssertTrue(
            try validate("1.0", ##"{"type":"integer","exclusiveMinimum":0,"exclusiveMaximum":2}"##)
                .valid)
        XCTAssertFalse(try validate("1.5", ##"{"type":"integer"}"##).valid)
        XCTAssertTrue(
            try validate(##""🐟a""##, ##"{"type":"string","minLength":2,"maxLength":2}"##).valid)
        XCTAssertTrue(try validate("null", ##"{"type":"string","nullable":true}"##).valid)
        XCTAssertFalse(
            try validate("null", ##"{"type":"string","nullable":true,"enum":["only"]}"##).valid)
        XCTAssertTrue(
            try validate(
                "2",
                ##"{"allOf":[{"minimum":1},{"maximum":3}],"oneOf":[{"type":"integer"},{"type":"string"}]}"##
            ).valid)
        XCTAssertFalse(
            try validate("2", ##"{"oneOf":[{"type":"number"},{"type":"integer"}]}"##).valid)
    }
    func testObjectsArraysReferencesAndUnsupportedRulesCannotPass() throws {
        let schema =
            ##"{"$defs":{"item":{"type":"object","required":["name"],"properties":{"name":{"type":"string"}},"additionalProperties":false}},"type":"array","minItems":1,"maxItems":2,"items":{"$ref":"#/$defs/item"}}"##
        XCTAssertTrue(try validate(##"[{"name":"ok"}]"##, schema).valid)
        XCTAssertFalse(try validate(##"[{"name":"ok","extra":1}]"##, schema).valid)
        XCTAssertFalse(try validate("[]", schema).valid)
        XCTAssertFalse(try validate(##"[{}]"##, schema).valid)
        let unsupported = try validate("{}", ##"{"properties":{"missing":{"pattern":"unsafe"}}}"##)
        XCTAssertFalse(unsupported.valid)
        XCTAssertEqual(unsupported.unsupported, ["pattern"])
        XCTAssertFalse(try validate("1", ##"{"$ref":"https://example.test/schema"}"##).valid)
        XCTAssertThrowsError(try validate("1", ##"{"$ref":"#"}"##))
        XCTAssertThrowsError(try validate("1", ##"{"minimum":"wrong"}"##))
        XCTAssertThrowsError(try validate(##"{"x":1,"x":2}"##, "true"))
    }
    func testUTF8PropertyNamesDoNotCanonicalizeOrCrash() throws {
        XCTAssertFalse(
            try validate(
                ##"{"e\u0301":1}"##,
                ##"{"properties":{"é":{"type":"number"}},"additionalProperties":false}"##
            ).valid)
        XCTAssertThrowsError(try validate("{}", ##"{"properties":{"é":true,"e\u0301":false}}"##))
    }
    func testAliasOptInBoundsCyclesAndForeignDefault() throws {
        let simple = Data("base: &base\n  type: string\ncopy: *base\n".utf8)
        XCTAssertThrowsError(try BoundedYAML.object(simple))
        let parsed = try BoundedYAML.object(simple, allowAliases: true)
        XCTAssertEqual((parsed["copy"] as? [String: Any])?["type"] as? String, "string")
        for source in [
            "a: &a [*a]", "a: *later\nb: &later value", "a: &same value\nb: &same other",
        ] {
            XCTAssertThrowsError(try BoundedYAML.object(Data(source.utf8), allowAliases: true))
        }
        let megabyte = String(repeating: "x", count: 1024 * 1024)
        let bomb =
            "a: &a " + megabyte + "\nb: ["
            + Array(repeating: "*a", count: 33).joined(separator: ",") + "]"
        XCTAssertThrowsError(try BoundedYAML.object(Data(bomb.utf8), allowAliases: true))
        var levels = "a: &a [x]\n"
        var previous = "a"
        for index in 0..<20 {
            let name = "n\(index)"
            levels += "\(name): &\(name) [*\(previous), *\(previous)]\n"
            previous = name
        }
        XCTAssertThrowsError(try BoundedYAML.object(Data(levels.utf8), allowAliases: true))
    }
}
