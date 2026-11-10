import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Makes the small previews that ship inside the app in place of the built-in media, which is
// downloaded the first time it's used. Run through make-previews.sh after changing Media/.
//
// - Footage: one frame per clip, as a JPEG tile picture.
// - Dynamic: a JPEG tile picture, plus a tiny HEIC holding every picture and the original's
//   schedule, so the app can show a wallpaper's day before it's downloaded.
// Both catalogs get each full file's size, shown on the tile and checked after a download.

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let media = root.appendingPathComponent("Media")
let resources = root.appendingPathComponent("Resources")

func writeJPEG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination), "couldn't write \(url.path)")
}

func size(of url: URL) -> Int {
    (try! FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue
}

func updateCatalog(_ folder: String, _ make: (inout [String: Any], URL, URL) throws -> Void) throws {
    let catalogURL = resources.appendingPathComponent("\(folder)/catalog.json")
    var entries = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as! [[String: Any]]
    let previews = resources.appendingPathComponent("\(folder)/previews")
    try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
    for index in entries.indices {
        let file = entries[index]["file"] as! String
        let source = media.appendingPathComponent("\(folder)/\(file)")
        try make(&entries[index], source, previews)
        entries[index]["bytes"] = size(of: source)
        print("\(folder)/\(file): \(size(of: source) / 1_000_000) MB")
    }
    let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: catalogURL)
}

let done = DispatchSemaphore(value: 0)
Task {
  do {
    try updateCatalog("Footage") { _, _, _ in }
    // Frames need async loading, so footage pictures are made in a second pass.
    let footage = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("Footage/catalog.json"))) as! [[String: Any]]
    for entry in footage {
        let file = entry["file"] as! String
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media.appendingPathComponent("Footage/\(file)")))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 400)
        let (image, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        writeJPEG(image, to: resources.appendingPathComponent("Footage/previews/\((file as NSString).deletingPathExtension).jpg"))
    }

    try updateCatalog("Dynamic") { _, source, previews in
        let stem = source.deletingPathExtension().lastPathComponent
        let original = CGImageSourceCreateWithURL(source as CFURL, nil)!
        let count = CGImageSourceGetCount(original)
        let schedule = DynamicSchedule.read(from: original)!
        let small: (Int, Int) -> CGImage = { index, pixels in
            CGImageSourceCreateThumbnailAtIndex(original, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ] as CFDictionary)!
        }
        writeJPEG(small(schedule.previewIndex, 720), to: previews.appendingPathComponent("\(stem).jpg"))

        let tiny = previews.appendingPathComponent("\(stem).heic")
        let destination = CGImageDestinationCreateWithURL(tiny as CFURL, UTType.heic.identifier as CFString, count, nil)!
        let options = [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary
        for index in 0..<count {
            if index == 0, let metadata = CGImageSourceCopyMetadataAtIndex(original, 0, nil) {
                CGImageDestinationAddImageAndMetadata(destination, small(index, 360), metadata, options)
            } else {
                CGImageDestinationAddImage(destination, small(index, 360), options)
            }
        }
        precondition(CGImageDestinationFinalize(destination), "couldn't write \(tiny.path)")
        let copy = DynamicSchedule.read(from: tiny)
        precondition(copy == schedule, "\(stem): the preview lost its schedule")
    }
  } catch {
    fatalError("\(error)")
  }
    done.signal()
}
done.wait()
