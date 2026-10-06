import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// "Create Click Flyer": the event as a ready-to-post image for an Instagram Story (9:16) or a
/// feed post (4:5). It's a Click ticket on a wash of the picture's own colors: the picture, the
/// title and who's hosting, then a tear line and a stub with the date, the place and a QR to
/// RSVP straight from a screenshot. Rendered on the device at 1080 px wide; the preview is the
/// exact image that's saved or shared.
struct ClickFlyerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let beacon: MapBeacon
    let shareURL: URL

    @State private var format: FlyerFormat = .story
    @State private var art: FlyerArt?
    @State private var rendered: [FlyerFormat: UIImage] = [:]
    @State private var isSaving = false
    @State private var linkCopied = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                linkPill
                Picker("Format", selection: $format) {
                    ForEach(FlyerFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                preview
            }
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .background(ClickColors.background.ignoresSafeArea())
            .navigationTitle("Click Flyer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                }
            }
            .task(id: format) { await render(format) }
            .alert("Click Flyer", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notice ?? "")
            }
        }
        .presentationDetents([.large])
    }

    /// The event link, one tap to copy (for a Story's link sticker).
    private var linkPill: some View {
        Button(action: copyLink) {
            HStack(spacing: 8) {
                Text(shareURL.host().map { "\($0)\(shareURL.path())" } ?? shareURL.absoluteString)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: linkCopied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(linkCopied ? ClickColors.online : ClickColors.textSecondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .font(ClickTypography.supporting)
            .foregroundStyle(ClickColors.textPrimary)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(ClickColors.fillSubtle, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(linkCopied ? "Link copied" : "Copy event link")
    }

    /// The flyer, as large as the screen allows (never scrolls, on any size).
    private var preview: some View {
        ZStack {
            if let flyer = rendered[format] {
                Image(uiImage: flyer)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
                    .accessibilityLabel("Flyer for \(beacon.title)")
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(ClickColors.fillSubtle)
                    .aspectRatio(format.size.width / format.size.height, contentMode: .fit)
                    .overlay { ProgressView() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(ClickMotion.subtleFade, value: rendered[format] != nil)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { Task { await save() } } label: {
                if isSaving { ProgressView() } else { Label("Save", systemImage: "square.and.arrow.down") }
            }
            .buttonStyle(.clickSecondary)
            .disabled(rendered[format] == nil || isSaving)

            if let flyer = rendered[format] {
                ShareLink(item: Image(uiImage: flyer), message: Text(shareURL.absoluteString),
                          preview: SharePreview(beacon.title, image: Image(uiImage: flyer))) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.clickPrimary)
            } else {
                Button {} label: { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.clickPrimary)
                    .disabled(true)
            }
        }
        .padding(.horizontal, ClickSpacing.screenGutter)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: 440 + 2 * ClickSpacing.screenGutter)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func copyLink() {
        UIPasteboard.general.string = shareURL.absoluteString
        ClickHaptics.success()
        withAnimation(ClickMotion.subtleFade) { linkCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(ClickMotion.subtleFade) { linkCopied = false }
        }
    }

    private func render(_ format: FlyerFormat) async {
        guard rendered[format] == nil else { return }
        if art == nil {
            var picture: UIImage?
            if let url = beacon.imageURL?.nonEmptyTrimmed.flatMap(URL.init(string:)) {
                picture = await ImagePipeline.shared.image(for: url, maxPixelSize: 1400)
            }
            art = FlyerArt(seed: beacon.id, picture: picture)
        }
        guard let art, !Task.isCancelled else { return }
        rendered[format] = FlyerCanvas.render(format: format, content: FlyerContent(beacon, link: shareURL), art: art)
    }

    private func save() async {
        guard let flyer = rendered[format], let data = flyer.pngData() else { return }
        isSaving = true
        defer { isSaving = false }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("click-flyer-\(UUID().uuidString).png")
        // Removed on every path, including a write that fails partway.
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try data.write(to: file)
            try await PhotoLibrarySaver.saveImage(at: file)
            ClickHaptics.success()
            notice = "Saved to Photos."
        } catch {
            notice = error.localizedDescription
        }
    }
}

// MARK: - Model

/// The two shapes Instagram takes: a Story (9:16) and a feed post (4:5), laid out at 360 pt wide
/// and rendered at 3× (1080 × 1920, 1080 × 1350).
enum FlyerFormat: String, CaseIterable, Identifiable {
    case story, post
    var id: String { rawValue }

    var title: String { self == .story ? "Story" : "Post" }

    var size: CGSize { self == .story ? CGSize(width: 360, height: 640) : CGSize(width: 360, height: 450) }

    var metrics: FlyerMetrics {
        switch self {
        case .story:
            FlyerMetrics(cardWidth: 284, photoAspects: 1.0...1.91, maxPhotoHeight: 250, plainAspect: 1.6, titleSize: 27, brandGap: 20)
        case .post:
            FlyerMetrics(cardWidth: 304, photoAspects: 1.7...2.4, maxPhotoHeight: 165, plainAspect: 2.1, titleSize: 23, brandGap: 14)
        }
    }
}

/// One format's ticket geometry (points).
struct FlyerMetrics: Equatable {
    let cardWidth: CGFloat
    /// The picture's frame follows its own shape within this range (width ÷ height).
    let photoAspects: ClosedRange<CGFloat>
    let maxPhotoHeight: CGFloat
    /// The frame for an event without a picture.
    let plainAspect: CGFloat
    let titleSize: CGFloat
    let brandGap: CGFloat

    static let inset: CGFloat = 12

    var photoWidth: CGFloat { cardWidth - 2 * Self.inset }

    /// The picture's frame: its own shape where the format allows, never taller than the cap.
    func photoFrame(for picture: CGSize?) -> CGSize {
        let aspect = picture.map { $0.width / max($0.height, 1) } ?? plainAspect
        let clamped = min(max(aspect, photoAspects.lowerBound), photoAspects.upperBound)
        return CGSize(width: photoWidth, height: min(photoWidth / clamped, maxPhotoHeight).rounded())
    }

    /// A picture close to its frame's shape fills it (a light crop); a poster far from it is
    /// shown whole over a blur of itself, so its text is never cut off.
    static func fills(_ picture: CGSize, frame: CGSize) -> Bool {
        let ratio = (picture.width / max(picture.height, 1)) / (frame.width / max(frame.height, 1))
        return (0.7...1.4).contains(ratio)
    }
}

/// What the flyer says, formatted once.
struct FlyerContent {
    let title: String
    let host: String?
    /// "SEP", "27".
    let month: String?
    let day: String?
    /// "Sat · 10:23 AM": absolute, since a flyer is read days later ("Today" would go stale).
    let when: String?
    let place: String?
    let link: URL
}

extension FlyerContent {
    init(_ beacon: MapBeacon, link: URL) {
        let start = beacon.schedule?.start
        self.init(
            title: beacon.title,
            host: (beacon.place?.name ?? beacon.visibleCreatorName).map { "Hosted by \($0)" },
            month: start?.formatted(.dateTime.month(.abbreviated)).uppercased(),
            day: start?.formatted(.dateTime.day()),
            when: start.map { "\($0.formatted(.dateTime.weekday(.abbreviated))) · \($0.formatted(date: .omitted, time: .shortened))" },
            place: beacon.locationName ?? beacon.formattedAddress,
            link: link
        )
    }
}

/// The picture and the colors drawn from it (or, without one, the event's generated colors).
struct FlyerArt {
    let picture: UIImage?
    /// The picture shrunk to a few pixels: stretched, it's a smooth wash of its colors.
    let swatch: UIImage?
    let gradient: [Color]
    let pattern: CardVisual.Pattern
    /// The date tile's month: the picture's color, deepened to read on white.
    let accent: Color

    init(seed: String, picture: UIImage?) {
        let visual = CardVisual(seed: seed)
        self.picture = picture
        swatch = picture.flatMap { $0.preparingThumbnail(of: CGSize(width: 16, height: 16 * $0.size.height / max($0.size.width, 1))) }
        gradient = visual.gradient.map(Color.init(hex:))
        pattern = visual.pattern
        let source = swatch.flatMap(Self.averageColor) ?? UIColor(hex: visual.gradient.first ?? "#7C3AED")
        accent = Color(uiColor: Self.deepened(source))
    }

    private static func averageColor(_ image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    /// Saturated and dark enough for small type on white; a grey picture falls back to Click violet.
    static func deepened(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation >= 0.18 else { return UIColor(hex: "#7C3AED") }
        return UIColor(hue: hue, saturation: max(saturation, 0.6), brightness: min(max(brightness, 0.45), 0.7), alpha: 1)
    }
}

// MARK: - Canvas

/// The flyer itself, at a fixed point size (type doesn't follow Dynamic Type: it's an image).
struct FlyerCanvas: View {
    let format: FlyerFormat
    let content: FlyerContent
    let art: FlyerArt

    /// The finished image at 3×.
    @MainActor
    static func render(format: FlyerFormat, content: FlyerContent, art: FlyerArt) -> UIImage? {
        ClickFonts.registerFonts()
        let renderer = ImageRenderer(content: FlyerCanvas(format: format, content: content, art: art))
        renderer.proposedSize = ProposedViewSize(format.size)
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage
    }

    private var metrics: FlyerMetrics { format.metrics }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: metrics.brandGap) {
                ticket
                brand
            }
        }
        .frame(width: format.size.width, height: format.size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    /// The picture's colors, stretched and softened, lit from the top and dimmed toward the
    /// bottom; a fine grain keeps the gradient from banding.
    private var backdrop: some View {
        ZStack {
            Color.black
            Color.clear.overlay {
                if let swatch = art.swatch {
                    Image(uiImage: swatch)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .blur(radius: 24)
                        .saturation(1.3)
                        .scaleEffect(1.25)
                } else {
                    LinearGradient(colors: art.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            RadialGradient(colors: [.white.opacity(0.18), .clear], center: UnitPoint(x: 0.2, y: 0),
                           startRadius: 0, endRadius: format.size.width)
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.28), .black.opacity(0.62)],
                           startPoint: .top, endPoint: .bottom)
            if let grain = FlyerGrain.image {
                Image(uiImage: grain)
                    .resizable(resizingMode: .tile)
                    .blendMode(.overlay)
                    .opacity(0.08)
            }
        }
        .clipped()
    }

    private var ticket: some View {
        VStack(alignment: .leading, spacing: 0) {
            photo
            Text(content.title)
                .font(.custom("Manrope-ExtraBold", fixedSize: metrics.titleSize))
                .kerning(-0.4)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, format == .story ? 14 : 12)
                .padding(.horizontal, 6)
            if let host = content.host {
                Text(host)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .padding(.top, 5)
                    .padding(.horizontal, 6)
            }
            Perforation()
                .padding(.vertical, 10)
            stub
        }
        .foregroundStyle(.white)
        .padding(FlyerMetrics.inset)
        .frame(width: metrics.cardWidth, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
            shape.fill(.white.opacity(0.13))
            shape.strokeBorder(.white.opacity(0.22), lineWidth: 1)
        }
        // The tear line's notches punch through the glass (see `Perforation`).
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.32), radius: 28, y: 16)
    }

    private var photo: some View {
        let frame = metrics.photoFrame(for: art.picture?.size)
        return ZStack {
            if let picture = art.picture {
                if FlyerMetrics.fills(picture.size, frame: frame) {
                    Color.clear.overlay { Image(uiImage: picture).resizable().scaledToFill() }
                } else {
                    Color.clear.overlay {
                        Image(uiImage: art.swatch ?? picture).resizable().interpolation(.high).scaledToFill().blur(radius: 8)
                    }
                    Color.black.opacity(0.15)
                    Image(uiImage: picture).resizable().scaledToFit()
                }
            } else {
                LinearGradient(colors: art.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                CardPatternLayer(pattern: art.pattern)
                Image(systemName: "calendar")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.25), radius: 6)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var stub: some View {
        HStack(spacing: 12) {
            if let month = content.month, let day = content.day {
                VStack(spacing: 1) {
                    Text(month)
                        .font(.system(size: 10, weight: .heavy))
                        .kerning(0.8)
                        .foregroundStyle(art.accent)
                    Text(day)
                        .font(.custom("Manrope-ExtraBold", fixedSize: 23))
                        .foregroundStyle(Color(white: 0.08))
                }
                .frame(width: 46, height: 52)
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                if let when = content.when {
                    Text(when)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if let place = content.place {
                    Text(place)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let qr = QRCodeRenderer.image(for: content.link.absoluteString) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
                    .frame(width: 58, height: 58)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var brand: some View {
        HStack(spacing: 7) {
            ClickLogo(style: .markDark, size: 20)
            Text("Click")
                .font(.custom("Manrope-ExtraBold", fixedSize: 16))
        }
        .foregroundStyle(.white.opacity(0.9))
    }
}

/// The ticket's tear line: a dashed rule between two notches punched out of the card's edges.
/// The notches erase the card's glass beneath them (`destinationOut`), so the backdrop shows
/// through; the card's `compositingGroup` keeps the erasing to the card.
private struct Perforation: View {
    private static let radius: CGFloat = 10

    var body: some View {
        ZStack {
            DashedRule()
                .stroke(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 5]))
                .frame(height: 1.5)
                .padding(.horizontal, Self.radius + 2)
            HStack(spacing: 0) {
                notch
                Spacer(minLength: 0)
                notch
            }
            .padding(.horizontal, -(FlyerMetrics.inset + Self.radius))
        }
        .frame(height: 2 * Self.radius)
    }

    private var notch: some View {
        ZStack {
            Circle().fill(.black).blendMode(.destinationOut)
            Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1)
        }
        .frame(width: 2 * Self.radius, height: 2 * Self.radius)
    }

    private struct DashedRule: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: 0, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

/// Film grain, made once: monochrome noise at the render's pixel size, tiled.
@MainActor
private enum FlyerGrain {
    static let image: UIImage? = {
        let size = 240
        let noise = CIFilter.randomGenerator().outputImage?
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                          "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        guard let noise, let cgImage = CIContext().createCGImage(noise, from: noise.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 3, orientation: .up)
    }()
}
