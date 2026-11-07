import CoreGraphics
import Foundation
import ImageIO

/// Cuts only along wide, empty gutters that span a whole region. A connected
/// diagram stays in one image, including branches with a shared shaft.
enum DiagramImageRegions {
    private static let maxPixels = 4_000_000
    private static let maxRegions = 5
    private static let minContentSpan = 56

    private struct Area {
        let columns: Range<Int>
        let rows: Range<Int>

        var width: Int { columns.count }
        var height: Int { rows.count }

        func padded(in image: Area) -> CGRect {
            let x = max(image.columns.lowerBound, columns.lowerBound - 12)
            let y = max(image.rows.lowerBound, rows.lowerBound - 12)
            return CGRect(x: x, y: y,
                          width: min(image.columns.upperBound, columns.upperBound + 12) - x,
                          height: min(image.rows.upperBound, rows.upperBound + 12) - y)
        }
    }

    private struct Projection {
        let area: Area
        let columns: [Bool]
        let rows: [Bool]

        var content: Area? {
            guard let left = columns.firstIndex(of: true), let right = columns.lastIndex(of: true),
                  let top = rows.firstIndex(of: true), let bottom = rows.lastIndex(of: true) else { return nil }
            let x = area.columns.lowerBound, y = area.rows.lowerBound
            return Area(columns: (x + left)..<(x + right + 1), rows: (y + top)..<(y + bottom + 1))
        }
    }

    static func crops(from url: URL) -> [CGImage]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= minContentSpan, height >= minContentSpan, width <= maxPixels / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height,
              let mask = foreground(in: image) else { return nil }

        let whole = Area(columns: 0..<width, rows: 0..<height)
        var regions = [whole]
        var index = 0
        while index < regions.count {
            guard let halves = split(regions[index], mask: mask, stride: width) else {
                index += 1
                continue
            }
            // Complex layouts stay in the normal whole-image path.
            guard regions.count < maxRegions else { return nil }
            regions.replaceSubrange(index...index, with: halves)
        }
        guard regions.count > 1 else { return nil }
        let crops = regions.compactMap { image.cropping(to: $0.padded(in: whole)) }
        return crops.count == regions.count ? crops : nil
    }

    private static func foreground(in image: CGImage) -> [Bool]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space, bitmapInfo: format) else { return nil }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(bounds)
            context.draw(image, in: bounds)
            let corners = [0, width - 1, width * (height - 1), width * height - 1]
            let lightest = corners.map { index in
                let offset = index * 4
                let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
                return (red: red, green: green, blue: blue, brightness: min(red, green, blue))
            }.max { $0.brightness < $1.brightness }
            guard let background = lightest, background.brightness >= 235 else { return nil }
            func isForeground(_ index: Int) -> Bool {
                let offset = index * 4
                return abs(Int(bytes[offset]) - background.red) > 6
                    || abs(Int(bytes[offset + 1]) - background.green) > 6
                    || abs(Int(bytes[offset + 2]) - background.blue) > 6
            }
            // A box or a screenshot border can touch a corner. Require the
            // chosen light background in at least two corners.
            guard corners.filter({ !isForeground($0) }).count >= 2 else { return nil }
            return (0..<(width * height)).map(isForeground)
        }
    }

    private static func project(_ area: Area, mask: [Bool], stride: Int) -> Projection {
        var columns = [Bool](repeating: false, count: area.width)
        var rows = [Bool](repeating: false, count: area.height)
        for (y, row) in area.rows.enumerated() {
            let offset = row * stride
            for (x, column) in area.columns.enumerated() where mask[offset + column] {
                rows[y] = true
                columns[x] = true
            }
        }
        return Projection(area: area, columns: columns, rows: rows)
    }

    private static func split(_ area: Area, mask: [Bool], stride: Int) -> [Area]? {
        let projection = project(area, mask: mask, stride: stride)
        guard let content = projection.content else { return nil }
        let minimumGap = max(40, min(content.width, content.height) / 14)
        var candidates: [(gap: Range<Int>, vertical: Bool)] = []
        for (lines, vertical) in [(projection.columns, true), (projection.rows, false)] {
            var lastOccupied: Int?
            for (index, occupied) in lines.enumerated() where occupied {
                if let last = lastOccupied, index - last - 1 >= minimumGap {
                    candidates.append(((last + 1)..<index, vertical))
                }
                lastOccupied = index
            }
        }
        candidates.sort { $0.gap.count > $1.gap.count }
        for (gap, vertical) in candidates.prefix(6) {
            let range = vertical ? area.columns : area.rows
            let start = range.lowerBound + gap.lowerBound, end = range.lowerBound + gap.upperBound
            let before = range.lowerBound..<start, after = end..<range.upperBound
            let halves = vertical
                ? [Area(columns: before, rows: area.rows), Area(columns: after, rows: area.rows)]
                : [Area(columns: area.columns, rows: before), Area(columns: area.columns, rows: after)]
            let content = halves.compactMap { project($0, mask: mask, stride: stride).content }
            if content.count == 2, content.allSatisfy({ $0.width >= minContentSpan && $0.height >= minContentSpan }) {
                return content
            }
        }
        return nil
    }
}
