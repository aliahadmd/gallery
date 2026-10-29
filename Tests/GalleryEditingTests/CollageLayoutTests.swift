import CoreGraphics
import Foundation
import Testing
@testable import GalleryEditing
import GalleryDomain

@Test func aspectCanvases() {
    #expect(CollageAspect.square.canvas(longSide: 3000) == PixelSize(width: 3000, height: 3000))
    #expect(CollageAspect.portrait4x5.canvas(longSide: 3000) == PixelSize(width: 2400, height: 3000))
    #expect(CollageAspect.landscape3x2.canvas(longSide: 3000) == PixelSize(width: 3000, height: 2000))
    #expect(CollageAspect.wide16x9.canvas(longSide: 3000) == PixelSize(width: 3000, height: 1688))
    #expect(CollageAspect.custom(width: 2, height: 1).canvas(longSide: 1000)
        == PixelSize(width: 1000, height: 500))
    #expect(CollageAspect.custom(width: 1, height: 0).canvas(longSide: 1000)
        == PixelSize(width: 1000, height: 1000))
}

@Test func twoUpGridTilesExactly() {
    let document = CollageDocument(
        memberIDs: [MediaID(rawValue: 1), MediaID(rawValue: 2)],
        template: .grid(columns: 2),
        aspect: .square,
        longSide: 1000,
        gutterFraction: 0.01,
        marginFraction: 0.05
    )
    let layout = CollageLayoutEngine.layout(document)
    #expect(layout.canvas == PixelSize(width: 1000, height: 1000))
    #expect(layout.slots.count == 2)
    #expect(layout.slots[0].frame == CGRect(x: 50, y: 50, width: 445, height: 900))
    #expect(layout.slots[1].frame == CGRect(x: 505, y: 50, width: 445, height: 900))
    #expect(layout.slots[0].requiredPixels == 900)
    #expect(layout.titleFrame == nil)
}

@Test func raggedLastRowSpreadsAcrossTheWidth() {
    let ids = (1...3).map { MediaID(rawValue: Int64($0)) }
    let document = CollageDocument(
        memberIDs: ids, template: .grid(columns: 2), aspect: .square,
        longSide: 1000, gutterFraction: 0.01, marginFraction: 0.05
    )
    let layout = CollageLayoutEngine.layout(document)
    #expect(layout.slots.count == 3)
    #expect(layout.slots[2].frame == CGRect(x: 50, y: 505, width: 900, height: 445))
}

@Test func heroTemplatesPlaceTheHero() {
    let ids = (1...3).map { MediaID(rawValue: Int64($0)) }
    let top = CollageDocument(
        memberIDs: ids, template: .heroTop, aspect: .square,
        longSide: 1000, gutterFraction: 0.01, marginFraction: 0.05
    )
    let topLayout = CollageLayoutEngine.layout(top)
    #expect(topLayout.slots.count == 3)
    #expect(topLayout.slots[0].frame == CGRect(x: 50, y: 50, width: 900, height: 552))
    #expect(topLayout.slots[1].frame.minY == 612)
    #expect(topLayout.slots[1].frame.height == 338)

    let left = CollageDocument(
        memberIDs: ids, template: .heroLeft, aspect: .square,
        longSide: 1000, gutterFraction: 0.01, marginFraction: 0.05
    )
    let leftLayout = CollageLayoutEngine.layout(left)
    #expect(leftLayout.slots[0].frame == CGRect(x: 50, y: 50, width: 516, height: 900))
    #expect(leftLayout.slots[1].frame == CGRect(x: 576, y: 50, width: 374, height: 445))
    #expect(leftLayout.slots[2].frame == CGRect(x: 576, y: 505, width: 374, height: 445))
}

@Test func collageTilingInvariants() {
    let aspects: [CollageAspect] = [.square, .portrait4x5, .landscape3x2, .wide16x9]
    let templates: [CollageTemplate] = [.grid(columns: 2), .grid(columns: 3), .heroTop, .heroLeft, .strip]
    for count in 1...12 {
        let ids = (1...count).map { MediaID(rawValue: Int64($0)) }
        for aspect in aspects {
            for template in templates {
                let document = CollageDocument(
                    memberIDs: ids, template: template, aspect: aspect, longSide: 2000
                )
                let layout = CollageLayoutEngine.layout(document)
                #expect(layout.slots.count == count, "\(template) \(aspect) n=\(count)")
                let canvasArea = Double(layout.canvas.width) * Double(layout.canvas.height)

                for slot in layout.slots {
                    let frame = slot.frame
                    #expect(frame.width >= 1 && frame.height >= 1)
                    #expect(frame.minX >= -0.001 && frame.minY >= -0.001)
                    #expect(frame.maxX <= Double(layout.canvas.width) + 0.001)
                    #expect(frame.maxY <= Double(layout.canvas.height) + 0.001)
                    #expect(slot.requiredPixels == Int32(max(frame.width, frame.height).rounded()))
                    #expect(slot.requiredPixels >= 1)
                    if let title = layout.titleFrame {
                        let overlap = frame.intersection(title)
                        #expect(overlap.isNull || overlap.height <= 0.001)
                    }
                }

                for i in 0..<layout.slots.count {
                    for j in (i + 1)..<layout.slots.count {
                        let overlap = layout.slots[i].frame.intersection(layout.slots[j].frame)
                        #expect(
                            overlap.isNull || overlap.width <= 0.001 || overlap.height <= 0.001,
                            "\(template) \(aspect) n=\(count): \(layout.slots[i].frame) ∩ \(layout.slots[j].frame)"
                        )
                    }
                }

                let margin = (0.02 * 2000).rounded()
                let canvas = aspect.canvas(longSide: 2000)
                let contentArea = (Double(canvas.width) - 2 * margin) * (Double(canvas.height) - 2 * margin)
                let slotArea = layout.slots.reduce(0.0) { $0 + $1.frame.width * $1.frame.height }
                #expect(slotArea <= contentArea + 1, "\(template) \(aspect) n=\(count)")
                #expect(slotArea >= contentArea * 0.6, "\(template) \(aspect) n=\(count)")
                #expect(slotArea < canvasArea)
            }
        }
    }
}

@Test func titleBandSitsUnderTheGrid() {
    let document = CollageDocument(
        memberIDs: [MediaID(rawValue: 1), MediaID(rawValue: 2)],
        template: .grid(columns: 2), aspect: .square,
        longSide: 1000, gutterFraction: 0.01, marginFraction: 0.05,
        title: "Trip"
    )
    let layout = CollageLayoutEngine.layout(document)
    #expect(layout.titleFrame == CGRect(x: 50, y: 880, width: 900, height: 70))
    #expect(layout.slots[0].frame.height == 820)
    #expect(layout.slots[0].frame.maxY == 870)

    let blank = CollageLayoutEngine.layout(
        CollageDocument(
            memberIDs: [MediaID(rawValue: 1)], template: .grid(columns: 2), aspect: .square,
            longSide: 1000, gutterFraction: 0.01, marginFraction: 0.05, title: "   "
        )
    )
    #expect(blank.titleFrame == nil)
}

@Test func upscaleFactorReportsTheLargestEnlargement() {
    let document = CollageDocument(
        memberIDs: [MediaID(rawValue: 1), MediaID(rawValue: 2)],
        template: .grid(columns: 2), aspect: .square,
        longSide: 1000, gutterFraction: 0.01, marginFraction: 0.05
    )
    let layout = CollageLayoutEngine.layout(
        document,
        sourceLongSides: [MediaID(rawValue: 1): 400, MediaID(rawValue: 2): 2000]
    )
    #expect(abs(layout.upscaleFactor - 900.0 / 400.0) < 1e-9)

    let none = CollageLayoutEngine.layout(document)
    #expect(none.upscaleFactor == 1)
}

@Test func emptyDocumentHasNoSlots() {
    let document = CollageDocument(memberIDs: [], template: .grid(columns: 2))
    let layout = CollageLayoutEngine.layout(document)
    #expect(layout.slots.isEmpty)
}

@Test func longSideIsClampedToTheDocumentRange() {
    let ids = [MediaID(rawValue: 1)]
    let tiny = CollageLayoutEngine.layout(
        CollageDocument(memberIDs: ids, aspect: .landscape3x2, longSide: 10)
    )
    #expect(tiny.canvas == PixelSize(width: 800, height: 533))
    let huge = CollageLayoutEngine.layout(
        CollageDocument(memberIDs: ids, aspect: .landscape3x2, longSide: 100_000)
    )
    #expect(huge.canvas == PixelSize(width: 8192, height: 5461))
}
