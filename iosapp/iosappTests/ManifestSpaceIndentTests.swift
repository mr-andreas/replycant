import GitDB
import Testing
import Yams

// The importer writes four-space YAML. Putting the space name on a
// two-space line makes that file unreadable, so a library update that
// includes those files never appears.
struct ManifestSpaceIndentTests {
    @Test func fourSpaceNameKeepsDeviceSpaceAsSibling() throws {
        let yaml = """
        metadata:
            name: clip
        spec:
            id: clip
        """
        let spaced = EncryptionLayout.yamlAssigningSpace("sim-seeder", to: yaml)
        let decoded = try YAMLDecoder().decode(Probe.self, from: spaced)
        #expect(decoded.metadata.name == "clip")
        #expect(decoded.metadata.deviceSpace == "sim-seeder")
        #expect(decoded.spec.id == "clip")
    }

    @Test func twoSpaceNameKeepsDeviceSpaceAsSibling() throws {
        let yaml = """
        metadata:
          name: clip
        spec:
          id: clip
        """
        let spaced = EncryptionLayout.yamlAssigningSpace("phone", to: yaml)
        let decoded = try YAMLDecoder().decode(Probe.self, from: spaced)
        #expect(decoded.metadata.deviceSpace == "phone")
    }

    private struct Probe: Codable {
        struct Meta: Codable {
            let name: String
            let deviceSpace: String
        }
        struct Spec: Codable {
            let id: String
        }
        let metadata: Meta
        let spec: Spec
    }
}
