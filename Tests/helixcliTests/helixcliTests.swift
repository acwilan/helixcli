import XCTest
@testable import helixcli

final class helixcliTests: XCTestCase {
    func testJSONResponseSuccess() {
        let response = JSONResponse.success(data: ["test": "value"])
        let json = response.toJSON()
        
        XCTAssertTrue(json.contains("\"success\": true"))
        XCTAssertTrue(json.contains("\"test\": \"value\""))
    }
    
    func testJSONResponseFailure() {
        let response = JSONResponse.failure(code: "TEST_ERROR", message: "Test message")
        let json = response.toJSON()
        
        XCTAssertTrue(json.contains("\"success\": false"))
        XCTAssertTrue(json.contains("\"code\": \"TEST_ERROR\""))
        XCTAssertTrue(json.contains("\"message\": \"Test message\""))
    }
    
    func testPresetModel() {
        let preset = Preset(id: 0, name: "Clean Tone", bank: "User")
        
        XCTAssertEqual(preset.id, 0)
        XCTAssertEqual(preset.name, "Clean Tone")
        XCTAssertEqual(preset.bank, "User")
    }
}
