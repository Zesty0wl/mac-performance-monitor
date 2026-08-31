// SPDX-License-Identifier: MIT

import Foundation

/// A rectangle in points, kept framework-free so the layout can live in Core
/// and be tested headless; the view converts to `CGRect` at its boundary.
public struct TreemapRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = TreemapRect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { max(0, width) * max(0, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func insetBy(_ amount: Double) -> TreemapRect {
        insetBy(top: amount, left: amount, bottom: amount, right: amount)
    }

    public func insetBy(top: Double, left: Double, bottom: Double, right: Double) -> TreemapRect {
        TreemapRect(
            x: x + left, y: y + top, width: max(0, width - left - right),
            height: max(0, height - top - bottom))
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }

    public func intersects(_ other: TreemapRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }
}

/// The squarified treemap of Bruls, Huizing and van Wijk: items are laid out
/// in rows along the shorter side of the remaining space, a row accepting the
/// next item only while that does not worsen the row's worst aspect ratio, so
/// cells come out as close to square as the data allows.
public enum TreemapLayout {
    /// One rectangle per weight, in the same order, tiling `bounds`. Weights
    /// are non-negative; largest first gives the best shapes. Zero weights
    /// (or an empty total, or empty bounds) yield empty rectangles at the
    /// bounds origin rather than NaNs.
    public static func squarify(weights: [Double], in bounds: TreemapRect) -> [TreemapRect] {
        let empty = TreemapRect(x: bounds.x, y: bounds.y, width: 0, height: 0)
        var result = [TreemapRect](repeating: empty, count: weights.count)
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0, bounds.width > 0, bounds.height > 0, !weights.isEmpty else {
            return result
        }
        let scale = bounds.area / total
        let areas = weights.map { max(0, $0) * scale }
        var remaining = bounds
        var index = 0
        while index < areas.count {
            if areas[index] <= 0 {
                index += 1
                continue
            }
            guard remaining.width > 0, remaining.height > 0 else { break }
            let side = min(remaining.width, remaining.height)
            var row = [index]
            var rowArea = areas[index]
            var worstSoFar = worst(
                rowMin: areas[index], rowMax: areas[index], rowArea: rowArea, side: side)
            var rowMin = areas[index]
            var rowMax = areas[index]
            var next = index + 1
            while next < areas.count, areas[next] > 0 {
                let candidateArea = rowArea + areas[next]
                let candidateMin = min(rowMin, areas[next])
                let candidateMax = max(rowMax, areas[next])
                let candidateWorst = worst(
                    rowMin: candidateMin, rowMax: candidateMax, rowArea: candidateArea, side: side)
                if candidateWorst <= worstSoFar {
                    row.append(next)
                    rowArea = candidateArea
                    rowMin = candidateMin
                    rowMax = candidateMax
                    worstSoFar = candidateWorst
                    next += 1
                } else {
                    break
                }
            }
            layout(row: row, areas: areas, rowArea: rowArea, remaining: &remaining, into: &result)
            index = next
        }
        return result
    }

    /// The worst aspect ratio in a row of total area `rowArea` laid along a
    /// side of length `side`; only the smallest and largest items matter.
    private static func worst(
        rowMin: Double, rowMax: Double, rowArea: Double, side: Double
    ) -> Double {
        let sideSquared = side * side
        let areaSquared = rowArea * rowArea
        return max(sideSquared * rowMax / areaSquared, areaSquared / (sideSquared * rowMin))
    }

    private static func layout(
        row: [Int], areas: [Double], rowArea: Double, remaining: inout TreemapRect,
        into result: inout [TreemapRect]
    ) {
        if remaining.width >= remaining.height {
            // A column down the left edge.
            let columnWidth = min(remaining.width, rowArea / remaining.height)
            var y = remaining.y
            for (position, item) in row.enumerated() {
                let height = areas[item] / columnWidth
                let isLast = position == row.count - 1
                let cellHeight = isLast ? remaining.maxY - y : height
                result[item] = TreemapRect(
                    x: remaining.x, y: y, width: columnWidth, height: max(0, cellHeight))
                y += height
            }
            remaining = TreemapRect(
                x: remaining.x + columnWidth, y: remaining.y,
                width: max(0, remaining.width - columnWidth), height: remaining.height)
        } else {
            // A row along the top edge.
            let rowHeight = min(remaining.height, rowArea / remaining.width)
            var x = remaining.x
            for (position, item) in row.enumerated() {
                let width = areas[item] / rowHeight
                let isLast = position == row.count - 1
                let cellWidth = isLast ? remaining.maxX - x : width
                result[item] = TreemapRect(
                    x: x, y: remaining.y, width: max(0, cellWidth), height: rowHeight)
                x += width
            }
            remaining = TreemapRect(
                x: remaining.x, y: remaining.y + rowHeight, width: remaining.width,
                height: max(0, remaining.height - rowHeight))
        }
    }
}

/// One drawn rectangle of a treemap scene.
public struct TreemapCell: Sendable, Equatable {
    /// The node drawn, or `TreemapCell.aggregateNode` for the "N more items"
    /// cell that stands in for a directory's tail of tiny children.
    public var node: Int32
    /// The directory whose area this cell tiles.
    public var parent: Int32
    public var rect: TreemapRect
    /// 0 for the children of the scene root.
    public var depth: Int
    public var isDirectory: Bool
    /// True when the directory's own children are drawn inside this cell.
    public var isSubdivided: Bool
    /// The title strip across the top of a subdivided directory, when there
    /// is room for one.
    public var labelStrip: TreemapRect?
    public var aggregateCount: UInt32
    public var aggregateBytes: UInt64

    public static let aggregateNode: Int32 = -1
    public var isAggregate: Bool { node == Self.aggregateNode }
}

public struct TreemapSceneOptions: Sendable, Equatable {
    /// Levels drawn below the scene root. Generous, because a cell is only
    /// subdivided when it has room (`subdivideMinimumWidth` by
    /// `subdivideMinimumHeight`), so the cell count is bounded by the area
    /// of the map rather than by this; a home folder needs four or five
    /// levels before the files that carry the colours come into view.
    public var depthLimit = 6
    /// Gap between sibling cells, in points.
    public var padding: Double = 1
    /// Children projected to less than this area fold into the aggregate cell.
    public var minimumCellArea: Double = 12
    /// A directory cell is subdivided only when at least this large.
    public var subdivideMinimumWidth: Double = 40
    public var subdivideMinimumHeight: Double = 28
    /// Title strip height and the width a cell needs before it gets one.
    public var stripHeight: Double = 16
    public var stripMinimumWidth: Double = 56
    /// Cells drawn per directory before the rest fold into the aggregate.
    public var maximumCellsPerDirectory = 160
    /// Packages (apps, bundles) are leaves unless the user zooms into them.
    public var descendIntoPackages = false

    public init() {}
}

/// The rectangles to draw for one zoom root: parents before their children
/// (draw order) so the deepest cell containing a point is the last match.
public struct TreemapScene: Sendable, Equatable {
    public var root: Int32
    public var bounds: TreemapRect
    public var cells: [TreemapCell]

    public static let empty = TreemapScene(root: 0, bounds: .zero, cells: [])

    public static func build(
        tree: FileTree, root: Int32, bounds: TreemapRect,
        options: TreemapSceneOptions = TreemapSceneOptions()
    ) -> TreemapScene {
        guard !tree.isEmpty, Int(root) < tree.nodeCount, !bounds.isEmpty else {
            return TreemapScene(root: root, bounds: bounds, cells: [])
        }
        var cells: [TreemapCell] = []
        cells.reserveCapacity(512)
        tile(tree: tree, directory: root, in: bounds, depth: 0, options: options, into: &cells)
        return TreemapScene(root: root, bounds: bounds, cells: cells)
    }

    /// The deepest cell under a point.
    public func hitTest(x: Double, y: Double) -> TreemapCell? {
        for cell in cells.reversed() where cell.rect.contains(x: x, y: y) {
            if cell.isSubdivided, let strip = cell.labelStrip, !strip.contains(x: x, y: y) {
                // Inside a subdivided directory but on none of its children
                // (a gap): the directory is still the right answer.
                return cell
            }
            return cell
        }
        return nil
    }

    public func cell(for node: Int32) -> TreemapCell? {
        cells.first { $0.node == node }
    }

    /// Cells that tile `directory` directly, in layout order.
    public func children(of directory: Int32) -> [TreemapCell] {
        cells.filter { $0.parent == directory }
    }

    private static func tile(
        tree: FileTree, directory: Int32, in rect: TreemapRect, depth: Int,
        options: TreemapSceneOptions, into cells: inout [TreemapCell]
    ) {
        guard !rect.isEmpty else { return }
        let ordered = tree.childrenBySize(of: directory).filter {
            tree.bytes[Int($0)] > 0 && !tree.flags[Int($0)].contains(.trashed)
        }
        guard !ordered.isEmpty else { return }
        let total = ordered.reduce(UInt64(0)) { $0 &+ tree.bytes[Int($1)] }
        guard total > 0 else { return }
        let areaPerByte = rect.area / Double(total)

        var kept: [Int32] = []
        var aggregateBytes: UInt64 = 0
        var aggregateCount: UInt32 = 0
        for child in ordered {
            let bytes = tree.bytes[Int(child)]
            let area = Double(bytes) * areaPerByte
            if kept.count < options.maximumCellsPerDirectory, area >= options.minimumCellArea {
                kept.append(child)
            } else {
                aggregateBytes &+= bytes
                aggregateCount &+=
                    tree.flags[Int(child)].contains(.smallFilesFold)
                    ? tree.count[Int(child)] : 1
            }
        }
        var weights = kept.map { Double(tree.bytes[Int($0)]) }
        if aggregateBytes > 0 { weights.append(Double(aggregateBytes)) }
        let rects = TreemapLayout.squarify(weights: weights, in: rect)

        for (position, child) in kept.enumerated() {
            let cellRect = gutter(rects[position], padding: options.padding, within: rect)
            guard !cellRect.isEmpty else { continue }
            let c = Int(child)
            let flags = tree.flags[c]
            let isDirectory = flags.contains(.directory)
            let listable = isDirectory && !flags.contains(.smallFilesFold) && tree.childCount[c] > 0
            let isPackage = flags.contains(.package)
            let canSubdivide =
                listable && depth + 1 < options.depthLimit
                && (!isPackage || options.descendIntoPackages)
                && cellRect.width >= options.subdivideMinimumWidth
                && cellRect.height >= options.subdivideMinimumHeight
            var strip: TreemapRect?
            var content = cellRect
            if canSubdivide {
                if cellRect.width >= options.stripMinimumWidth,
                    cellRect.height >= options.stripHeight * 2
                {
                    strip = TreemapRect(
                        x: cellRect.x, y: cellRect.y, width: cellRect.width,
                        height: options.stripHeight)
                    content = cellRect.insetBy(
                        top: options.stripHeight + options.padding, left: options.padding,
                        bottom: options.padding, right: options.padding)
                } else {
                    content = cellRect.insetBy(options.padding * 2)
                }
            }
            cells.append(
                TreemapCell(
                    node: child, parent: directory, rect: cellRect, depth: depth,
                    isDirectory: isDirectory, isSubdivided: canSubdivide, labelStrip: strip,
                    aggregateCount: 0, aggregateBytes: 0))
            if canSubdivide {
                tile(
                    tree: tree, directory: child, in: content, depth: depth + 1,
                    options: options, into: &cells)
            }
        }
        if aggregateBytes > 0, let last = rects.last {
            let cellRect = gutter(last, padding: options.padding, within: rect)
            if !cellRect.isEmpty {
                cells.append(
                    TreemapCell(
                        node: TreemapCell.aggregateNode, parent: directory, rect: cellRect,
                        depth: depth, isDirectory: false, isSubdivided: false, labelStrip: nil,
                        aggregateCount: aggregateCount, aggregateBytes: aggregateBytes))
            }
        }
    }

    /// Leave a gap on the right and bottom of a cell, except where the cell
    /// already touches the enclosing edge.
    private static func gutter(
        _ r: TreemapRect, padding: Double, within outer: TreemapRect
    )
        -> TreemapRect
    {
        let right = r.maxX >= outer.maxX - 0.01 ? 0 : padding
        let bottom = r.maxY >= outer.maxY - 0.01 ? 0 : padding
        return TreemapRect(
            x: r.x, y: r.y, width: max(0, r.width - right), height: max(0, r.height - bottom))
    }
}
