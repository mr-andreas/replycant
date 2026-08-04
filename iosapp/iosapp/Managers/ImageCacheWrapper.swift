import Foundation
import UIKit
import LRUCache

// Wraps LRUCache library for UIImage storage with memory-based eviction.
// Calculates UIImage memory footprint and uses cost-based limits to prevent unbounded memory growth.
@MainActor
final class ImageCacheWrapper {
    private let cache: LRUCache<String, UIImage>
    
    init(maxMemoryMB: Int) {
        let maxMemoryBytes = maxMemoryMB * 1024 * 1024
        self.cache = LRUCache<String, UIImage>(totalCostLimit: maxMemoryBytes)
    }
    
    // Updates the maximum memory limit and evicts items if necessary.
    func setMaxMemoryMB(_ mb: Int) {
        let newMaxBytes = mb * 1024 * 1024
        cache.totalCostLimit = newMaxBytes
    }
    
    // Retrieves a cached image and marks it as recently used.
    func get(for key: String) -> UIImage? {
        return cache.value(forKey: key)
    }
    
    // Stores an image in the cache with memory-based eviction.
    // Evicts least recently used items if adding this image would exceed the memory limit.
    func set(_ image: UIImage, for key: String) {
        let imageMemory = calculateImageMemory(image)
        cache.setValue(image, forKey: key, cost: Int(imageMemory))
    }
    
    // Removes a specific item from the cache.
    func remove(for key: String) {
        cache.removeValue(forKey: key)
    }
    
    // Clears all cached items.
    func clear() {
        cache.removeAll()
    }
    
    // Returns the current memory usage in bytes.
    // Note: LRUCache doesn't expose current cost, so we estimate based on cached images.
    func currentMemoryUsageBytes() -> Int64 {
        var total: Int64 = 0
        for key in cache.keys {
            if let image = cache.value(forKey: key) {
                total += calculateImageMemory(image)
            }
        }
        return total
    }
    
    // Returns the maximum memory limit in bytes.
    func maxMemoryBytesLimit() -> Int64 {
        return Int64(cache.totalCostLimit)
    }
    
    // Calculates the memory footprint of a UIImage.
    // Assumes RGBA format: width * height * 4 bytes per pixel.
    private func calculateImageMemory(_ image: UIImage) -> Int64 {
        let size = image.size
        let scale = image.scale
        let width = Int64(size.width * scale)
        let height = Int64(size.height * scale)
        return width * height * 4 // RGBA = 4 bytes per pixel
    }
}

