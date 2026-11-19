import Foundation
import LibGit2
import Yams

// Names who can unwrap a key set. The global list is the library.
// A space list, when present, adds holders who cannot read the rest.
public struct RecipientList: Equatable {
    public var members: [String]

    public init(members: [String]) {
        self.members = members
    }

    public func yaml() throws -> String {
        try YAMLEncoder().encode(File(members: members))
    }

    public static func parse(_ text: String) throws -> RecipientList {
        let file = try YAMLDecoder().decode(File.self, from: text)
        var seen: Set<String> = []
        for name in file.members {
            guard isValidName(name), seen.insert(name).inserted else {
                throw RecipientListError.invalid
            }
        }
        return RecipientList(members: file.members)
    }

    // Reads the list at one key-set root. A missing file is not an
    // error: a space with no extra holders omits it, and a library
    // that has not been migrated yet has none.
    public static func read(in repository: Repository, root: String) throws -> RecipientList? {
        let path = "\(root)/recipients.yaml"
        guard repository.fileExists(at: path) else {
            return nil
        }
        return try parse(repository.readFile(at: path))
    }

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter, first.isLowercase else {
            return false
        }
        guard name.count <= 253 else {
            return false
        }
        return name.allSatisfy { char in
            char.isLetter && char.isLowercase || char.isNumber || char == "-"
        }
    }

    private struct File: Codable {
        var members: [String]
    }
}

public enum RecipientListError: Error {
    case invalid
}
