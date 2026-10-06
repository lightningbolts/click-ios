import SwiftUI

/// "Create Click Flyer": the event as a ready-to-post image for an Instagram Story (9:16) or a
/// feed post (4:5) — its picture over a wash of its own colors, the when and where set large, and
/// a QR to the event so anyone can RSVP from a screenshot. Rendered on the device at 1080 px wide.
struct ClickFlyerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let beacon: MapBeacon
    let shareURL: URL

    enum Format: String, CaseIterable, Identifiable {
        case story = "Story"
        case post = "Post"
        var id: String { rawValue }

        /// Points; rendered at 3× (1080 × 1920 and 1080 × 1350).
        var canvas: CGSize {
            switch self {
            case .story: CGSize(width: 360, height: 640)
            case .post: CGSize(width: 360, height: 450)
            }
        }
    }

    @State private var format: Format = .story
    @State private var picture: UIImage?
    @State private var hasLoadedPicture = false
    @State private var rendered: [Format: UIImage] = [:]
    @State private var isSaving = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Picker("Format", selection: $format) {
                        ForEach(Format.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    ZStack {
                        if let flyer = rendered[format] {
                            Image(uiImage: flyer)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                                .accessibilityLabel("Flyer preview for \(beacon.title)")
                                .transition(.opacity)
                        } else {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(ClickColors.fillSubtle)
                                .aspectRatio(format.canvas.width / format.canvas.height, contentMode: .fit)
                                .overlay { ProgressView() }
                        }
                    }
                    .frame(maxHeight: 520)
                    .animation(ClickMotion.subtleFade, value: rendered[format] != nil)
                }
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ClickSpacing.screenGutter)
                .padding(.vertical, 12)
            }
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
        .background(.bar)
    }

    private func render(_ format: Format) async {
        guard rendered[format] == nil else { return }
        if !hasLoadedPicture {
            hasLoadedPicture = true
            if let url = beacon.imageURL?.nonEmptyTrimmed.flatMap(URL.init(string:)) {
                picture = await ImagePipeline.shared.image(for: url, maxPixelSize: 1400)
            }
        }
        ClickFonts.registerFonts()
        let canvas = FlyerCanvas(
            format: format,
            seed: beacon.id,
            title: beacon.title,
            when: beacon.schedule.map { EventFormatting.when($0) },
            place: beacon.locationName ?? beacon.formattedAddress,
            host: beacon.place?.name ?? beacon.visibleCreatorName,
            picture: picture,
            qr: QRCodeRenderer.image(for: shareURL.absoluteString),
            link: shareURL.host().map { "\($0)\(shareURL.path())" } ?? shareURL.absoluteString
        )
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 3
        if let image = renderer.uiImage { rendered[format] = image }
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

/// The flyer itself, drawn at a fixed point size (type doesn't follow Dynamic Type: it's an image).
private struct FlyerCanvas: View {
    let format: ClickFlyerSheet.Format
    let seed: String
    let title: String
    let when: String?
    let place: String?
    let host: String?
    let picture: UIImage?
    let qr: UIImage?
    let link: String

    private var isStory: Bool { format == .story }

    var body: some View {
        let size = format.canvas
        ZStack {
            backdrop
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: isStory ? 18 : 12)
                poster(width: size.width - 48)
                Spacer(minLength: isStory ? 18 : 12)
                details
                Spacer(minLength: isStory ? 18 : 12)
                footer
            }
            .padding(24)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    /// The picture blurred to a wash (else the event's generated colors), darkened for the type.
    private var backdrop: some View {
        ZStack {
            EventVisual(seed: seed, cornerRadius: 0)
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 36)
                    .opacity(0.9)
            }
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.55), .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ClickLogo(style: .markDark, size: 26)
            Text("Click")
                .font(.custom("Manrope-ExtraBold", fixedSize: 18))
            Spacer(minLength: 0)
            Text("YOU'RE INVITED")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.6)
                .opacity(0.8)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func poster(width: CGFloat) -> some View {
        let maxHeight: CGFloat = isStory ? 300 : 150
        let aspect: CGFloat = picture.map { min(max($0.size.width / max($0.size.height, 1), 0.8), 1.78) } ?? 16 / 9
        let posterWidth = min(width, maxHeight * aspect)
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        Group {
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFill()
            } else {
                EventVisual(seed: seed, symbol: "calendar", cornerRadius: 0)
            }
        }
        .frame(width: posterWidth, height: posterWidth / aspect)
        .clipShape(shape)
        .overlay(shape.stroke(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
        .frame(maxWidth: .infinity)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let when {
                Text(when.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(title)
                .font(.custom("Manrope-ExtraBold", fixedSize: isStory ? 34 : 28))
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
            if let place {
                Label(place, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
            if let host {
                Text("Hosted by \(host)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let qr {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
                    .frame(width: isStory ? 64 : 56, height: isStory ? 64 : 56)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("RSVP on Click")
                    .font(.system(size: 15, weight: .bold))
                Text(link)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .opacity(0.75)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
