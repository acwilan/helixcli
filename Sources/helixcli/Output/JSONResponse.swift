import Foundation

struct JSONResponse {
    let success: Bool
    let data: Any?
    let error: ResponseError?
    
    struct ResponseError: Codable {
        let code: String
        let message: String
    }
    
    static func success(data: Any?) -> JSONResponse {
        return JSONResponse(success: true, data: data, error: nil)
    }
    
    static func failure(code: String, message: String) -> JSONResponse {
        return JSONResponse(success: false, data: nil, error: ResponseError(code: code, message: message))
    }
    
    func toJSON() -> String {
        var dict: [String: Any] = [
            "success": success
        ]
        
        if let data = data {
            dict["data"] = data
        }
        
        if let error = error {
            dict["error"] = [
                "code": error.code,
                "message": error.message
            ]
        }
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            return String(data: jsonData, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"success\":false,\"error\":{\"code\":\"JSON_ERROR\",\"message\":\"Failed to serialize response\"}}"
        }
    }
}

// Convenience error responses
extension JSONResponse {
    static func deviceNotFound() -> JSONResponse {
        return failure(code: "DEVICE_NOT_FOUND", message: "HX Stomp not connected via USB")
    }
    
    static func usbError(_ message: String) -> JSONResponse {
        return failure(code: "USB_ERROR", message: message)
    }
    
    static func protocolError(_ message: String) -> JSONResponse {
        return failure(code: "PROTOCOL_ERROR", message: message)
    }
}
