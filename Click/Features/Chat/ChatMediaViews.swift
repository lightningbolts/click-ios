import CoreImage
import AVFoundation
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Audio playback (one shared player, spec §37.6)

/// The single audio player for chat and profile media. Only one voice note plays at a time;
/// state is keyed by message ID so a failure never leaks into another conversation's bubble.
@Observable
@MainActor
final class AudioPlaybackService: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlaybackService()

    private(set) var activeMessageID: String?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Pause when headphones are unplugged rather than playing out loud.
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            if reason == .oldDeviceUnavailable {
                MainActor.assumeIsolated { self?.pause() }
            }
        }
    }

    func isActive(_ messageID: String) -> Bool { activeMessageID == messageID }

    func play(url: URL, messageID: String) throws {
        if activeMessageID == messageID, let player {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
            startTicker()
            return
        }
        stop()
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        let next = try AVAudioPlayer(contentsOf: url)
        next.delegate = self
        next.prepareToPlay()
        player = next
        activeMessageID = messageID
        duration = next.duration
        currentTime = 0
        next.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.invalidate()
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(1, fraction)) * player.duration
        currentTime = player.currentTime
    }

    func stop() {
        player?.stop()
        player = nil
        activeMessageID = nil
        isPlaying = false
        currentTime = 0
        ticker?.invalidate()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            self.isPlaying = false
            self.currentTime = 0
            self.ticker?.invalidate()
        }
    }
}

// MARK: - Voice note recording

/// One recording session at a time; microphone permission is requested in context.
@Observable
@MainActor
final class VoiceNoteRecorder {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case denied
    }

    private(set) var state: State = .idle
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    static let maxDuration: TimeInterval = 180

    func start() async {
        guard state == .idle || state == .denied else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .denied
            return
        }
        AudioPlaybackService.shared.stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let next = try AVAudioRecorder(url: url, settings: settings)
            guard next.record(forDuration: Self.maxDuration) else { throw CocoaError(.fileWriteUnknown) }
            recorder = next
            fileURL = url
            state = .recording(startedAt: .now)
            ClickHaptics.impact(.light)
        } catch {
            cancel()
        }
    }

    /// Stops and returns the recording as an upload-ready draft (nil when too short).
    func finish() -> MediaDraft? {
        guard case .recording(let startedAt) = state, let recorder, let fileURL else { return nil }
        recorder.stop()
        let seconds = Int(Date.now.timeIntervalSince(startedAt).rounded())
        reset()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard seconds >= 1, let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        return MediaDraft(kind: .audio, data: data, mimeType: "audio/mp4", fileName: nil, durationSeconds: seconds)
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        reset()
    }

    private func reset() {
        recorder = nil
        fileURL = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Draft preparation

enum MediaDraftBuilder {
    /// Downscales and re-encodes a picked photo as JPEG off the main actor.
    static func image(from data: Data) async -> MediaDraft? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            let maxSide: CGFloat = 2048
            let scale = min(1, maxSide / max(image.size.width, image.size.height))
            let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
            guard let jpeg = resized.jpegData(compressionQuality: 0.82) else { return nil }
            return MediaDraft(kind: .image, data: jpeg, mimeType: "image/jpeg")
        }.value
    }

    static func file(at url: URL) throws -> MediaDraft {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return MediaDraft(kind: .file, data: data, mimeType: mime, fileName: url.lastPathComponent)
    }
}

// MARK: - Bubble content

/// Renders a media message's content. Loading is delegated to the conversation so decrypted
/// bytes are fetched once and failures stay scoped to this conversation.
struct MessageMediaContent: View {
    let message: ChatMessageItem
    let media: MessageMedia
    let load: () async throws -> URL
    let onOpen: (URL) -> Void

    var body: some View {
        switch media.kind {
        case .image: ChatImageView(message: message, load: load, onOpen: onOpen)
        case .audio: ChatAudioView(message: message, media: media, load: load)
        case .file: ChatFileView(message: message, media: media, load: load, onOpen: onOpen)
        }
    }
}

private struct ChatImageView: View {
    let message: ChatMessageItem
    let load: () async throws -> URL
    let onOpen: (URL) -> Void

    @State private var image: UIImage?
    @State private var url: URL?
    @State private var failed = false

    private var lockedUntil: Date? {
        guard let media = message.media, media.isLocked() else { return nil }
        return media.revealAt ?? .distantFuture
    }

    static func pixelated(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter(name: "CIPixellate")
        filter?.setValue(input, forKey: kCIInputImageKey)
        filter?.setValue(max(image.size.width, image.size.height) / 12, forKey: kCIInputScaleKey)
        guard let output = filter?.outputImage?.cropped(to: input.extent),
              let cg = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Reserved box until the image decodes, so the timeline doesn't jump (spec §37.4).
    private let placeholderSize = CGSize(width: 240, height: 200)

    var body: some View {
        Group {
            if let image, let url {
                if let revealAt = lockedUntil {
                    // Click Drop: heavily pixelated for everyone until 24 h after it was taken.
                    Image(uiImage: Self.pixelated(image) ?? image)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(image.size, contentMode: .fit)
                        .frame(maxWidth: 240, maxHeight: 320)
                        .overlay {
                            VStack(spacing: 4) {
                                Image(systemName: "hourglass")
                                Text("Click Drop · develops \(revealAt.formatted(.relative(presentation: .named)))")
                                    .font(ClickTypography.metadataEmphasized)
                            }
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.45), in: Capsule())
                        }
                        .accessibilityLabel("Click Drop photo, develops \(revealAt.formatted(.relative(presentation: .named)))")
                } else {
                    Button { onOpen(url) } label: {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(image.size, contentMode: .fit)
                            .frame(maxWidth: 240, maxHeight: 320)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Photo. Opens full screen.")
                }
            } else if failed {
                Button {
                    failed = false
                    Task { await fetch() }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text("Couldn't load photo. Tap to retry.")
                            .font(ClickTypography.metadata)
                    }
                    .foregroundStyle(ClickColors.textSecondary)
                    .frame(width: placeholderSize.width, height: placeholderSize.height)
                }
                .buttonStyle(.plain)
            } else {
                ProgressView()
                    .frame(width: placeholderSize.width, height: placeholderSize.height)
            }
        }
        .background(ClickColors.fillSubtle)
        .clipShape(RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous))
        .task(id: message.id) { await fetch() }
    }

    private func fetch() async {
        guard image == nil else { return }
        do {
            let fileURL = try await load()
            let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                return UIImage(data: data)?.preparingForDisplay()
            }.value
            guard let decoded else { throw ChatRepositoryError.mediaUnavailable }
            url = fileURL
            image = decoded
        } catch {
            failed = true
        }
    }
}

private struct ChatAudioView: View {
    let message: ChatMessageItem
    let media: MessageMedia
    let load: () async throws -> URL

    @State private var player = AudioPlaybackService.shared
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var scrub: Double?

    private var isActive: Bool { player.isActive(message.id) }
    private var total: TimeInterval {
        isActive && player.duration > 0 ? player.duration : TimeInterval(media.durationSeconds ?? 0)
    }
    private var elapsed: TimeInterval { isActive ? player.currentTime : 0 }

    var body: some View {
        HStack(spacing: 10) {
            Button { Task { await toggle() } } label: {
                ZStack {
                    if isLoading {
                        ProgressView().tint(foreground)
                    } else {
                        Image(systemName: isActive && player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                .foregroundStyle(foreground)
                .frame(width: 36, height: 36)
                .background(foreground.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isActive && player.isPlaying ? "Pause voice note" : "Play voice note")

            VStack(alignment: .leading, spacing: 2) {
                // A custom scrubber: the knob follows the finger 1:1 and its drag has priority
                // over swipe-to-reply and the timeline scroll.
                AudioScrubber(
                    progress: scrub ?? (total > 0 ? elapsed / total : 0),
                    tint: foreground,
                    isEnabled: isActive,
                    onScrub: { scrub = $0 },
                    onCommit: { value in
                        if isActive { player.seek(to: value) }
                        scrub = nil
                    }
                )
                Text(errorText ?? timeLabel)
                    .font(ClickTypography.caption)
                    .monospacedDigit()
                    .foregroundStyle(foreground.opacity(0.8))
            }
        }
        .frame(width: 230)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            message.isOutgoing ? ClickColors.messageOutgoing : ClickColors.messageIncoming,
            in: RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous)
        )
    }

    private var foreground: Color {
        message.isOutgoing ? ClickColors.messageOutgoingForeground : ClickColors.messageIncomingForeground
    }

    private var timeLabel: String {
        let format: (TimeInterval) -> String = { value in
            let seconds = Int(value.rounded())
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return isActive ? "\(format(elapsed)) / \(format(total))" : format(total)
    }

    private func toggle() async {
        if isActive, player.isPlaying {
            player.pause()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let url = try await load()
            try player.play(url: url, messageID: message.id)
            errorText = nil
        } catch {
            errorText = "Couldn't play"
        }
    }
}

private struct ChatFileView: View {
    let message: ChatMessageItem
    let media: MessageMedia
    let load: () async throws -> URL
    let onOpen: (URL) -> Void

    @State private var isLoading = false
    @State private var failed = false

    var body: some View {
        Button { Task { await open() } } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.displayName)
                        .font(ClickTypography.supportingEmphasized)
                        .lineLimit(2)
                    Text(detail)
                        .font(ClickTypography.caption)
                        .opacity(0.8)
                }
                Spacer(minLength: 0)
                if isLoading { ProgressView() }
            }
            .foregroundStyle(message.isOutgoing ? ClickColors.messageOutgoingForeground : ClickColors.messageIncomingForeground)
            .frame(width: 240, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                message.isOutgoing ? ClickColors.messageOutgoing : ClickColors.messageIncoming,
                in: RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(media.displayName), \(detail)")
    }

    private var icon: String {
        let mime = media.mimeType.lowercased()
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.contains("zip") { return "doc.zipper" }
        if mime.contains("csv") { return "tablecells" }
        return "doc"
    }

    private var detail: String {
        if failed { return "Couldn't open. Tap to retry." }
        let size = media.sizeBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [size, media.fileExtension.uppercased()].compactMap { $0 }.joined(separator: " · ")
    }

    private func open() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            onOpen(try await load())
            failed = false
        } catch {
            failed = true
        }
    }
}

// MARK: - Fullscreen viewer (spec §38)

/// The one fullscreen image viewer: zoom, pan, share of decrypted local bytes, and native
/// dismissal (close button or swipe down).
struct MediaViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragDismiss: CGFloat = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(x: offset.width, y: offset.height + dragDismiss)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { scale = max(1, min(5, lastScale * $0.magnification)) }
                                .onEnded { _ in
                                    lastScale = scale
                                    if scale == 1 { offset = .zero }
                                }
                                .simultaneously(with: DragGesture()
                                    .onChanged { value in
                                        if scale > 1 { offset = value.translation } else { dragDismiss = max(0, value.translation.height) }
                                    }
                                    .onEnded { value in
                                        if scale == 1, value.translation.height > 120 { dismiss() }
                                        withAnimation(ClickMotion.selection) { dragDismiss = 0 }
                                    })
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(ClickMotion.selection) {
                                scale = scale > 1 ? 1 : 2.5
                                lastScale = scale
                                offset = .zero
                            }
                        }
                        .accessibilityLabel("Photo")
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
        .task {
            image = await Task.detached { UIImage(contentsOfFile: url.path) }.value
        }
    }
}

// MARK: - Composer attachment controls

/// Composer "+" menu: photo, camera, Click Drop, file, voice message, and event/beacon share.
struct ComposerAttachmentButton: View {
    let onDraft: (MediaDraft) -> Void
    let onError: (String) -> Void
    var onVoice: (() -> Void)?
    var onShareBeacon: (() -> Void)?

    private enum Camera: Identifiable {
        case photo, clickDrop
        var id: Self { self }
    }

    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var camera: Camera?
    @State private var photoItem: PhotosPickerItem?

    private var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        Menu {
            if hasCamera {
                Button("Take Photo", systemImage: "camera") { camera = .photo }
            }
            Button("Photo Library", systemImage: "photo.on.rectangle") { showingPhotos = true }
            Button("Click Drop", systemImage: "hourglass") {
                if hasCamera { camera = .clickDrop } else { onError("Click Drops need a camera.") }
            }
            if let onVoice {
                Button("Voice Message", systemImage: "mic") { onVoice() }
            }
            if let onShareBeacon {
                Button("Share Event or Beacon", systemImage: "mappin.and.ellipse") { onShareBeacon() }
            }
            Button("File", systemImage: "doc") { showingFiles = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ClickColors.textSecondary)
                .frame(width: 36, height: 40)
        }
        .accessibilityLabel("Attach")
        .photosPicker(isPresented: $showingPhotos, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: Self.fileTypes) { result in
            if case .success(let url) = result {
                do { onDraft(try MediaDraftBuilder.file(at: url)) } catch { onError("Couldn't read that file.") }
            }
        }
        .fullScreenCover(item: $camera) { mode in
            CameraCapture { image in
                camera = nil
                guard let image, let data = image.jpegData(compressionQuality: 0.9) else { return }
                Task {
                    guard var draft = await MediaDraftBuilder.image(from: data) else {
                        onError("Couldn't prepare that photo.")
                        return
                    }
                    draft.isClickDrop = mode == .clickDrop
                    onDraft(draft)
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let draft = await MediaDraftBuilder.image(from: data) else {
                    onError("Couldn't prepare that photo.")
                    return
                }
                onDraft(draft)
            }
        }
    }

    /// Only types the server accepts for chat attachments.
    private static let fileTypes: [UTType] = [.pdf, .plainText, .commaSeparatedText, .zip, .png, .jpeg, .quickTimeMovie, .mpeg4Movie]
        + [UTType("org.openxmlformats.wordprocessingml.document")].compactMap { $0 }
}

/// System camera capture (photo only).
struct CameraCapture: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}

/// Seek bar whose knob tracks the finger exactly.
struct AudioScrubber: View {
    let progress: Double
    let tint: Color
    let isEnabled: Bool
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.25)).frame(height: 4)
                Capsule().fill(tint).frame(width: width * clamped, height: 4)
                Circle().fill(tint).frame(width: 14, height: 14)
                    .offset(x: width * clamped - 7)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        onScrub(min(max(value.location.x / width, 0), 1))
                    }
                    .onEnded { value in
                        guard isEnabled else { return }
                        onCommit(min(max(value.location.x / width, 0), 1))
                    },
                including: isEnabled ? .all : .none
            )
        }
        .frame(height: 22)
        .opacity(isEnabled ? 1 : 0.6)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.1 : -0.1
            onCommit(min(max(progress + step, 0), 1))
        }
    }
}

/// Picks a cached nearby beacon or saved event to share as a card.
struct BeaconSharePicker: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onPick: (MapBeacon) -> Void

    @State private var beacons: [MapBeacon] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List(beacons) { beacon in
                Button {
                    onPick(beacon)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        EventVisual(seed: beacon.id, imageURL: beacon.imageURL, symbol: beacon.kind.systemImage)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(beacon.title).foregroundStyle(ClickColors.textPrimary).lineLimit(1)
                            Text([beacon.kind.label, beacon.schedule.map { EventFormatting.when($0) }, beacon.locationName]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(ClickTypography.supporting)
                                .foregroundStyle(ClickColors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if loaded, beacons.isEmpty {
                    ContentUnavailableView("Nothing to share yet", systemImage: "mappin.slash",
                                           description: Text("Events and beacons near you or saved by you show up here."))
                } else if !loaded {
                    ProgressView()
                }
            }
            .navigationTitle("Share Event or Beacon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        defer { loaded = true }
        guard let userID = env.session.currentSession?.userId else { return }
        var result = (await env.beacons.cachedDiscovery(userID: userID))?.beacons.filter { $0.isActive() } ?? []
        // Saved events are resolved to full beacons so the card carries real fields.
        let saved = (try? await env.beacons.bookmarks(userID: userID)) ?? []
        for event in saved.prefix(10) where event.isAvailable && !result.contains(where: { $0.id == event.beaconID }) {
            if let full = try? await env.beacons.beacon(id: event.beaconID).beacon { result.append(full) }
        }
        beacons = result.sorted { ($0.isEvent ? 0 : 1, $0.title) < ($1.isEvent ? 0 : 1, $1.title) }
    }
}

/// Recording strip shown in place of the text field while a voice note records.
struct VoiceRecordingBar: View {
    let startedAt: Date
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Image(systemName: "trash")
                    .foregroundStyle(ClickColors.destructive)
                    .frame(width: 36, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard voice note")

            Circle().fill(ClickColors.destructive).frame(width: 8, height: 8)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(startedAt))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(ClickTypography.body)
                    .monospacedDigit()
                    .foregroundStyle(ClickColors.textPrimary)
            }
            Text("Recording")
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textSecondary)
            Spacer()
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(ClickColors.primaryActionForeground)
                    .frame(width: 40, height: 40)
                    .background(ClickColors.primaryActionFill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send voice note")
        }
    }
}
