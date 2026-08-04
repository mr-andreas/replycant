import Foundation
import UIKit

class DeviceIdentifierManager {
    static let shared = DeviceIdentifierManager()
    private let deviceIdKey = "deviceSpaceIdentifier"
    
    private init() {}
    
    var deviceSpaceIdentifier: String {
        get {
            if let storedId = UserDefaults.standard.string(forKey: deviceIdKey) {
                return storedId
            } else {
                let newId = generateDeviceSpaceIdentifier()
                UserDefaults.standard.set(newId, forKey: deviceIdKey)
                return newId
            }
        }
    }
    
    private func generateDeviceSpaceIdentifier() -> String {
        let deviceName = UIDevice.current.name
        let strippedDeviceName = stripDeviceName(deviceName)
        let uuid = UUID().uuidString.lowercased()
        return "\(strippedDeviceName)-\(uuid)"
    }
    
    private func stripDeviceName(_ deviceName: String) -> String {
        // Convert to lowercase and replace invalid characters with hyphens
        let stripped = deviceName.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression) // Replace multiple hyphens with single
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")) // Remove leading/trailing hyphens
        
        // Ensure it starts with a letter and limit to 50 characters
        let result = stripped.isEmpty ? "device" : stripped
        let finalResult = result.hasPrefix("-") ? "device-\(result)" : result
        
        // Limit to 50 characters for the device name part
        if finalResult.count > 50 {
            return String(finalResult.prefix(50))
        }
        
        return finalResult
    }
}
