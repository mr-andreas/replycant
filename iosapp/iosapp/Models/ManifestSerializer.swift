import Foundation
import Yams

struct ManifestSerializer {
    static func toYAML(_ manifest: OriginalManifest) -> String {
        let encoder = YAMLEncoder()
        do {
            let yaml = try encoder.encode(manifest)
            return yaml
        } catch {
            fatalError("Failed to encode manifest: \(error)")
        }
    }
    
    static func toYAML(_ manifest: ThumbnailSetManifest) -> String {
        let encoder = YAMLEncoder()
        do {
            let yaml = try encoder.encode(manifest)
            return yaml
        } catch {
            fatalError("Failed to encode manifest: \(error)")
        }
    }
    
    static func fromYAML(_ yaml: String) throws -> OriginalManifest {
        let decoder = YAMLDecoder()
        let manifest = try decoder.decode(OriginalManifest.self, from: yaml)
        return manifest
    }
    
    static func fromYAMLThumbnailSet(_ yaml: String) throws -> ThumbnailSetManifest {
        let decoder = YAMLDecoder()
        let manifest = try decoder.decode(ThumbnailSetManifest.self, from: yaml)
        return manifest
    }
}

