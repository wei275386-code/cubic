import Foundation

/// Reads the entitlements carried by the running executable's embedded code signature.
/// No CKContainer, provisioning-profile assumption, or private SecTask API is used on iOS.
enum CloudSyncEntitlements {
    private struct SignatureCapability: Sendable {
        let services: [String]
        let containers: [String]
        let environment: String?
    }
    private static let capability: SignatureCapability? = {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let entitlements = signedEntitlements(data) else { return nil }
        return SignatureCapability(services: entitlements["com.apple.developer.icloud-services"] as? [String] ?? [],
            containers: entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] ?? [],
            environment: entitlements["com.apple.developer.icloud-container-environment"] as? String)
    }()
    static func requirement(containerID: String) -> String? {
        guard let capability else {
            return "无法验证 executable 的 signed iCloud entitlement；需要启用 CloudKit capability 并重新签名。"
        }
        guard capability.services.contains("CloudKit"), capability.containers.contains(containerID),
              capability.environment.map({ ["Development", "Production"].contains($0) }) == true else {
            return "当前签名未包含 \(containerID) 的 CloudKit entitlement；本地离线可用，自动同步 requiresSigning。"
        }
        return nil
    }
    private static func signedEntitlements(_ data: Data) -> [String: Any]? {
        func word(_ offset: Int, big: Bool = false) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            var value: UInt32 = 0
            for i in 0..<4 {
                let byte = UInt32(data[offset + i])
                let shift = (big ? 3 - i : i) * 8
                value |= byte << shift
            }
            return value
        }
        var slice = 0, size = data.count
        if word(0, big: true) == 0xcafebabe || word(0, big: true) == 0xcafebabf {
            let fat64 = word(0, big: true) == 0xcafebabf
            guard let count = word(4, big: true), count <= 100 else { return nil }
            #if arch(arm64)
            let cpu: UInt32 = 0x0100000c
            #elseif arch(x86_64)
            let cpu: UInt32 = 0x01000007
            #else
            return nil
            #endif
            var found = false
            for i in 0..<Int(count) {
                let base = 8 + i * (fat64 ? 32 : 20)
                guard word(base, big: true) == cpu else { continue }
                if fat64 {
                    guard let highOffset = word(base + 8, big: true), highOffset == 0,
                          let offset = word(base + 12, big: true), let highSize = word(base + 16, big: true), highSize == 0,
                          let length = word(base + 20, big: true) else { return nil }
                    slice = Int(offset); size = Int(length)
                } else {
                    guard let offset = word(base + 8, big: true), let length = word(base + 12, big: true) else { return nil }
                    slice = Int(offset); size = Int(length)
                }
                found = true; break
            }
            guard found, slice <= data.count, size <= data.count - slice else { return nil }
        }
        guard let magic = word(slice), [UInt32(0xfeedfacf), 0xfeedface].contains(magic),
              let count = word(slice + 16), count <= 100_000 else { return nil }
        var command = slice + (magic == 0xfeedfacf ? 32 : 28)
        for _ in 0..<Int(count) {
            guard let kind = word(command), let length = word(command + 4), length >= 8,
                  command <= slice + size - Int(length) else { return nil }
            if kind == 0x1d {
                guard length >= 16, let offset = word(command + 8), let signatureSize = word(command + 12),
                      Int(offset) <= size, Int(signatureSize) <= size - Int(offset) else { return nil }
                let signature = slice + Int(offset), end = signature + Int(signatureSize)
                guard word(signature, big: true) == 0xfade0cc0, let slots = word(signature + 8, big: true), slots <= 1000 else { return nil }
                for slot in 0..<Int(slots) {
                    let index = signature + 12 + slot * 8
                    guard index <= end - 8, let type = word(index, big: true), let blobOffset = word(index + 4, big: true),
                          Int(blobOffset) <= Int(signatureSize) - 8 else { return nil }
                    guard type == 5 else { continue }
                    let blob = signature + Int(blobOffset)
                    guard word(blob, big: true) == 0xfade7171, let blobLength = word(blob + 4, big: true), blobLength >= 8,
                          Int(blobLength) <= end - blob else { return nil }
                    return (try? PropertyListSerialization.propertyList(from: data.subdata(in: (blob + 8)..<(blob + Int(blobLength))), options: [], format: nil)) as? [String: Any]
                }
                return nil // DER-only signature is conservatively unavailable; never invoke CloudKit speculatively.
            }
            command += Int(length)
        }
        return nil
    }
}
