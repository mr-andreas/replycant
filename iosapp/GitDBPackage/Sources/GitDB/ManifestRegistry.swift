import Foundation
import Yams

// Describes one SQL column extracted from a registered manifest kind.
public struct ManifestColumnDef {
    public let name: String
    public let sqlType: String
    public let nullable: Bool

    public init(name: String, sqlType: String, nullable: Bool) {
        self.name = name
        self.sqlType = sqlType
        self.nullable = nullable
    }
}

// Describes one SQL index for a registered manifest kind table.
public struct ManifestIndexDef {
    public let columns: [String]
    public let whereClause: String?

    public init(columns: [String], whereClause: String? = nil) {
        self.columns = columns
        self.whereClause = whereClause
    }
}

// Enumerates supported SQL scalar values for registered extracted columns.
public enum ManifestSQLValue: Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case data(Data)
    case null
}

// Constrains registration column SQL type declarations to known values.
public enum ManifestColumnType: String {
    case text = "TEXT"
    case integer = "INTEGER"
    case real = "REAL"
    case blob = "BLOB"
}

// Builds one manifest kind registration so app code can define schema details declaratively.
public final class ManifestRegistrationBuilder<T: Manifest> {
    private(set) var columns: [ManifestColumnDef] = []
    private(set) var indexes: [ManifestIndexDef] = []
    private(set) var extractor: ((T) -> [String: ManifestSQLValue])?

    // Adds one extracted SQL column for this manifest type.
    public func column(_ name: String, type: ManifestColumnType, nullable: Bool = false) {
        columns.append(ManifestColumnDef(name: name, sqlType: type.rawValue, nullable: nullable))
    }

    // Adds one SQL index declaration for this manifest type.
    public func index(on columns: [String], where whereClause: String? = nil) {
        indexes.append(ManifestIndexDef(columns: columns, whereClause: whereClause))
    }

    // Captures how to project one manifest instance into registered SQL columns.
    public func extractColumns(_ extractor: @escaping (T) -> [String: ManifestSQLValue]) {
        self.extractor = extractor
    }
}

// Stores registered manifest decoding and table-shape metadata for schema-agnostic storage.
public final class ManifestRegistry: @unchecked Sendable {
    // Represents all decoding and table generation data for one kind.
    public struct Registration {
        public let kind: String
        public let tableName: String
        public let columns: [ManifestColumnDef]
        public let indexes: [ManifestIndexDef]
        let decode: (String) throws -> any Manifest
        let extract: (any Manifest) throws -> [String: ManifestSQLValue]
    }

    private var byKind: [String: Registration] = [:]
    private let lock = NSLock()

    public init() {}

    // Registers one manifest type so sync and storage can decode and persist it generically.
    public func register<T: Manifest>(_ type: T.Type, configure: (ManifestRegistrationBuilder<T>) -> Void) {
        let builder = ManifestRegistrationBuilder<T>()
        configure(builder)
        let tableName = Self.tableName(forKind: type.kind)
        let decoder = YAMLDecoder()
        let registration = Registration(
            kind: type.kind,
            tableName: tableName,
            columns: builder.columns,
            indexes: builder.indexes,
            decode: { yaml in
                try decoder.decode(T.self, from: yaml)
            },
            extract: { manifest in
                guard let typed = manifest as? T else {
                    throw NotSupportedError("Registered extractor type mismatch for kind \(type.kind)")
                }
                return builder.extractor?(typed) ?? [:]
            }
        )
        lock.lock()
        byKind[type.kind] = registration
        lock.unlock()
    }

    // Looks up and decodes one YAML payload by registered kind.
    func decode(kind: String, yaml: String) throws -> (any Manifest)? {
        lock.lock()
        let registration = byKind[kind]
        lock.unlock()
        return try registration?.decode(yaml)
    }

    // Returns all registrations for table creation and mutation routing.
    func allRegistrations() -> [Registration] {
        lock.lock()
        let result = Array(byKind.values)
        lock.unlock()
        return result
    }

    // Resolves the registration for one manifest kind.
    func registration(forKind kind: String) -> Registration? {
        lock.lock()
        let result = byKind[kind]
        lock.unlock()
        return result
    }

    // Resolves the generated table name for one manifest type.
    public func tableName<T: Manifest>(for type: T.Type) throws -> String {
        guard let registration = registration(forKind: type.kind) else {
            throw NotSupportedError("No registration found for kind \(type.kind)")
        }
        return registration.tableName
    }

    // Produces deterministic SQL-safe table names for manifest kinds.
    static func tableName(forKind kind: String) -> String {
        let normalized = kind.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "_"
        }
        return "manifests_" + String(normalized)
    }
}
