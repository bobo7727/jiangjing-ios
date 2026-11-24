import UIKit

/// Draws the label stamp onto a photo. Pure drawing: it knows nothing about purchases.
enum LabelRenderer {
    /// Returns a new image with the stamp. The source is never modified.
    static func render(image: UIImage, text: String, position: LabelPosition) -> UIImage {
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
            guard !text.isEmpty else { return }
            let layout = LabelLayout.make(imageWidth: Double(size.width), imageHeight: Double(size.height))
            let font = UIFont.systemFont(ofSize: layout.fontSize, weight: .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph
            ]
            let maxText = CGFloat(layout.maxTextWidth - 2 * layout.padding)
            let measured = (text as NSString).size(withAttributes: [.font: font])
            let textWidth = min(ceil(measured.width), maxText)
            let textHeight = ceil(font.lineHeight)
            let boxWidth = textWidth + CGFloat(2 * layout.padding)
            let boxHeight = textHeight + CGFloat(2 * layout.padding)
            let originX = CGFloat(layout.originX(position: position, imageWidth: Double(size.width), boxWidth: Double(boxWidth)))
            let originY = CGFloat(layout.originY(imageHeight: Double(size.height), boxHeight: Double(boxHeight)))
            let box = CGRect(x: originX, y: originY, width: boxWidth, height: boxHeight)
            UIColor.black.withAlphaComponent(0.55).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: CGFloat(layout.cornerRadius)).fill()
            (text as NSString).draw(
                in: CGRect(x: box.minX + CGFloat(layout.padding), y: box.minY + CGFloat(layout.padding),
                           width: textWidth, height: textHeight),
                withAttributes: attributes
            )
        }
    }

    /// A smaller copy for the live preview. The layout scales with width, so it looks like the export.
    static func previewBase(of image: UIImage, maxDimension: CGFloat = 1080) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let ratio = maxDimension / longest
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// JPEG bytes of the stamped photo read from `url`, or nil if it cannot be read or encoded.
    static func stampedJPEG(from url: URL, text: String, position: LabelPosition, quality: CGFloat) -> Data? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return render(image: image, text: text, position: position).jpegData(compressionQuality: quality)
    }
}
