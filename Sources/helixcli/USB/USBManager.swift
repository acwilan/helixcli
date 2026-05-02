import Foundation
import IOKit
import IOKit.usb

enum USBError: Error {
    case deviceNotFound
    case connectionFailed
    case transferFailed
    case invalidResponse
}

/// Manages USB communication with HX Stomp
actor USBManager {
    // Line 6 Vendor ID
    static let vendorId: UInt16 = 0x0E6F
    // HX Stomp Product ID (needs verification)
    static let productId: UInt16 = 0x0003 // Placeholder - verify with actual device
    
    private var device: IOUSBDeviceInterface?
    private var interface: IOUSBInterfaceInterface?
    private var isConnected: Bool = false
    
    init() throws {
        // TODO: Initialize USB connection
    }
    
    /// Connect to HX Stomp device
    func connect() async throws {
        // TODO: Implement actual USB device discovery and connection
        // 1. Find matching USB device via IOKit
        // 2. Open device
        // 3. Claim interface
        // 4. Set configuration
        
        // For now, just mark as connected for testing
        isConnected = true
        var stderr = StandardErrorOutputStream()
        print("Connected to HX Stomp (stub)", to: &stderr)
    }
    
    /// Disconnect from device
    func disconnect() async {
        isConnected = false
        // TODO: Release interfaces and close device
    }
    
    /// Send command to device and wait for response
    func sendCommand(_ command: HelixCommand) async throws -> Data {
        guard isConnected else {
            throw USBError.deviceNotFound
        }
        
        // TODO: Implement actual USB transfer
        // 1. Build packet
        // 2. Send via USB bulk/control transfer
        // 3. Wait for response
        // 4. Parse response
        
        return Data() // Stub
    }
    
    /// Get device info
    func getDeviceInfo() async throws -> [String: Any] {
        return [
            "vendorId": String(format: "0x%04X", USBManager.vendorId),
            "productId": String(format: "0x%04X", USBManager.productId),
            "connected": isConnected
        ]
    }
}

/// Standard error output stream for debug messages
struct StandardErrorOutputStream: TextOutputStream {
    mutating func write(_ string: String) {
        guard !string.isEmpty else { return }
        FileHandle.standardError.write(Data(string.utf8))
    }
}
