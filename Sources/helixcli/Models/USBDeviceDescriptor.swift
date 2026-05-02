import Foundation

struct USBDeviceDescriptor: Codable {
    let vendorId: UInt16
    let productId: UInt16
    let vendorName: String?
    let productName: String?
    let serialNumber: String?
    let registryPath: String?
    let isSupportedHelixDevice: Bool

    var deviceId: String {
        String(format: "%04x:%04x", vendorId, productId)
    }

    var dictionary: [String: Any] {
        [
            "vendorId": String(format: "0x%04X", vendorId),
            "productId": String(format: "0x%04X", productId),
            "deviceId": deviceId,
            "vendorName": vendorName as Any,
            "productName": productName as Any,
            "serialNumber": serialNumber as Any,
            "registryPath": registryPath as Any,
            "isSupportedHelixDevice": isSupportedHelixDevice,
        ]
    }
}
