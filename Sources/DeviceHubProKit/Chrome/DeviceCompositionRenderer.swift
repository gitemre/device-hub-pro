import CoreGraphics

/// Draws a vector or Apple chrome `DeviceComposition` into a bitmap with
/// CoreGraphics, for the static consumers (the stopped device's hero,
/// framed screenshots). The live stage draws the same plan with SwiftUI; a
/// parity test holds the two together.
public enum DeviceCompositionRenderer {
    /// Vector and Apple chrome plans; nil for a skin plan or an empty
    /// canvas.
    ///
    /// An sRGB bitmap (8-bit RGBA, premultiplied) of
    /// ceil(`layoutSize` × `pixelsPerUnit`) pixels, transparent outside the
    /// body. The bands are filled outside-in, each at least one pixel wide;
    /// then `drawScreen` draws the screen with the context already clipped to
    /// the screen's corner; then the cutout is filled black over it.
    ///
    /// `drawScreen` gets the context in CoreGraphics' own y-up space and the
    /// screen rect in that space, so `context.draw(image, in: rect)` draws a
    /// capture upright.
    public static func render(
        _ c: DeviceComposition,
        pixelsPerUnit: CGFloat,
        drawScreen: (CGContext, CGRect) -> Void
    ) -> CGImage? {
        guard pixelsPerUnit > 0, pixelsPerUnit.isFinite else { return nil }
        if case let .appleChrome(chrome) = c.body {
            return renderAppleChrome(c, chrome: chrome, pixelsPerUnit: pixelsPerUnit, drawScreen: drawScreen)
        }
        guard case .vector = c.body else { return nil }
        let width = Int((c.layoutSize.width * pixelsPerUnit).rounded(.up))
        let height = Int((c.layoutSize.height * pixelsPerUnit).rounded(.up))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high

        // The plan is top-left based; CoreGraphics user space is y-up, so
        // every rect is flipped around the canvas height.
        let placed = c.placed(pointsPerUnit: pixelsPerUnit, pixelScale: 1)
        let canvasHeight = CGFloat(height)
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: canvasHeight - rect.maxY, width: rect.width, height: rect.height)
        }

        for band in placed.bands {
            guard let path = roundedRect(flipped(band.rect), radius: band.cornerRadius) else { continue }
            context.addPath(path)
            context.setFillColor(band.color.srgbColor)
            context.fillPath()
        }

        let screen = flipped(placed.screen)
        guard let screenPath = roundedRect(screen, radius: placed.screenCornerRadius) else {
            return context.makeImage()
        }
        context.saveGState()
        context.addPath(screenPath)
        context.clip()
        drawScreen(context, screen)
        if let cutout = placed.cutout?.path(in: placed.screen) {
            var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvasHeight)
            if let path = cutout.copy(using: &flip) {
                context.addPath(path)
                context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
                context.fillPath()
            }
        }
        context.restoreGState()
        return context.makeImage()
    }

    /// An Apple chrome plan: the buttons drawn under the body, the body (its
    /// slices and the black glass they leave uncovered), the screen
    /// (`drawScreen`, in y-up pixels, clipped to the screen's outline:
    /// `AppleChromeDrawing.clipToScreen`), then the buttons drawn over the
    /// body; every button at rest. The chrome is drawn native and turned with the
    /// plan (`AppleChromeBody.pointsToUnits`).
    private static func renderAppleChrome(
        _ c: DeviceComposition,
        chrome: DeviceComposition.AppleChromeBody,
        pixelsPerUnit: CGFloat,
        drawScreen: (CGContext, CGRect) -> Void
    ) -> CGImage? {
        let width = Int((c.layoutSize.width * pixelsPerUnit).rounded(.up))
        let height = Int((c.layoutSize.height * pixelsPerUnit).rounded(.up))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        let canvasHeight = CGFloat(height)
        // Chrome points, y-down, turned with the plan.
        func inChromeSpace(_ draw: () -> Void) {
            context.saveGState()
            context.translateBy(x: 0, y: canvasHeight)
            context.scaleBy(x: pixelsPerUnit, y: -pixelsPerUnit)
            context.concatenate(chrome.pointsToUnits)
            draw()
            context.restoreGState()
        }
        inChromeSpace {
            AppleChromeDrawing.drawButtons(chrome.layout, art: chrome.art, onTop: false, in: context)
            AppleChromeDrawing.drawBody(chrome.layout, art: chrome.art, in: context)
        }
        let screen = CGRect(
            x: c.screenRect.minX * pixelsPerUnit,
            y: canvasHeight - c.screenRect.maxY * pixelsPerUnit,
            width: c.screenRect.width * pixelsPerUnit,
            height: c.screenRect.height * pixelsPerUnit
        )
        context.saveGState()
        AppleChromeDrawing.clipToScreen(
            screen,
            quarterTurns: chrome.quarterTurns,
            art: chrome.art,
            cornerRadius: chrome.cornerRadius * chrome.unitsPerPoint * pixelsPerUnit,
            context: context
        )
        drawScreen(context, screen)
        context.restoreGState()
        inChromeSpace {
            AppleChromeDrawing.drawButtons(chrome.layout, art: chrome.art, onTop: true, in: context)
        }
        return context.makeImage()
    }

    /// A rounded rect CoreGraphics accepts (it traps on a corner wider than
    /// half the rect); nil for an empty rect.
    private static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let corner = min(max(radius, 0), rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }
}
