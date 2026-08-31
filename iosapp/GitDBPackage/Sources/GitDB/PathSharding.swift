import Foundation

// Shards manifest and binary filenames into prefix directories to keep git tree fanout bounded.
public func shardName(_ name: String) -> String {
    if name.count < 5 {
        return name
    }
    let first = String(name.prefix(2))
    let second = String(name.dropFirst(2).prefix(2))
    let rest = String(name.dropFirst(4))
    return "\(first)/\(second)/\(rest)"
}
