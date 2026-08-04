import Foundation

// Encodes and decodes Bech32 strings so age public keys can be exchanged in a compact interoperable format.
enum Bech32 {
    // Signals Bech32 parse and encoding failures that must stop key exchange to avoid corrupt identities.
    enum Error: Swift.Error {
        case invalidLength
        case mixedCase
        case missingSeparator
        case invalidCharacter
        case invalidChecksum
        case invalidData
    }

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let generator: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    private static let separator: Character = "1"

    // Produces a checksummed Bech32 string for binary key material that will be embedded in QR/device metadata.
    static func encode(hrp: String, data: Data) throws -> String {
        let lowerHRP = hrp.lowercased()
        let fiveBit = try convertBits(Array(data), from: 8, to: 5, pad: true)
        let checksum = createChecksum(hrp: lowerHRP, data: fiveBit)
        let combined = fiveBit + checksum
        let chars = try combined.map { value -> Character in
            guard Int(value) < charset.count else {
                throw Error.invalidData
            }
            return charset[Int(value)]
        }
        return lowerHRP + String(separator) + String(chars)
    }

    // Parses a Bech32 string and validates checksum to ensure exchanged age keys have not been truncated or tampered.
    static func decode(_ value: String) throws -> (hrp: String, data: Data) {
        guard value.count >= 8 else {
            throw Error.invalidLength
        }
        guard value.lowercased() == value || value.uppercased() == value else {
            throw Error.mixedCase
        }

        let normalized = value.lowercased()
        guard let separatorIndex = normalized.lastIndex(of: separator) else {
            throw Error.missingSeparator
        }

        let hrp = String(normalized[..<separatorIndex])
        let payloadStart = normalized.index(after: separatorIndex)
        let payload = String(normalized[payloadStart...])
        guard !hrp.isEmpty, payload.count >= 6 else {
            throw Error.invalidLength
        }

        let values: [UInt8] = try payload.map { char in
            guard let index = charset.firstIndex(of: char) else {
                throw Error.invalidCharacter
            }
            return UInt8(index)
        }

        guard verifyChecksum(hrp: hrp, data: values) else {
            throw Error.invalidChecksum
        }

        let dataWithoutChecksum = Array(values.dropLast(6))
        let eightBit = try convertBits(dataWithoutChecksum, from: 5, to: 8, pad: false)
        return (hrp, Data(eightBit))
    }

    // Converts values between bit-widths so binary keys can be represented in Bech32 character alphabet.
    private static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) throws -> [UInt8] {
        var accumulator: Int = 0
        var bits: Int = 0
        let maxValue = (1 << to) - 1
        var result: [UInt8] = []

        for value in data {
            guard (Int(value) >> from) == 0 else {
                throw Error.invalidData
            }
            accumulator = (accumulator << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                result.append(UInt8((accumulator >> bits) & maxValue))
            }
        }

        if pad {
            if bits > 0 {
                result.append(UInt8((accumulator << (to - bits)) & maxValue))
            }
        } else if bits >= from || ((accumulator << (to - bits)) & maxValue) != 0 {
            throw Error.invalidData
        }

        return result
    }

    // Computes Bech32 polynomial checksum to detect copy/scan errors in exchanged public keys.
    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var check: UInt32 = 1
        for value in values {
            let top = check >> 25
            check = (check & 0x1ffffff) << 5 ^ UInt32(value)
            for (index, coefficient) in generator.enumerated() where ((top >> index) & 1) != 0 {
                check ^= coefficient
            }
        }
        return check
    }

    // Expands human-readable prefix into values included in checksum calculation per BIP-0173.
    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        var values: [UInt8] = []
        values.reserveCapacity(hrp.count * 2 + 1)
        for scalar in hrp.unicodeScalars {
            values.append(UInt8(scalar.value >> 5))
        }
        values.append(0)
        for scalar in hrp.unicodeScalars {
            values.append(UInt8(scalar.value & 31))
        }
        return values
    }

    // Builds checksum suffix appended to encoded payload so decoders can reject malformed key strings.
    private static func createChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
        let values = hrpExpand(hrp) + data + Array(repeating: 0, count: 6)
        let mod = polymod(values) ^ 1
        return (0..<6).map { i in
            UInt8((mod >> UInt32(5 * (5 - i))) & 31)
        }
    }

    // Validates checksum to prevent accepting corrupted age public key payloads from QR scans.
    private static func verifyChecksum(hrp: String, data: [UInt8]) -> Bool {
        polymod(hrpExpand(hrp) + data) == 1
    }
}
