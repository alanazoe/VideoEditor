//
//  EditorViewModel.swift
//  VideoEditorSwiftUI
//
//  Created by Bogdan Zykov on 14.04.2023.
//

import Foundation
import AVKit
import SwiftUI
import Photos
import Combine
import AVFoundation

// MARK: - Persistence DTOs for multi-clip projects
private struct ClipDTO: Codable {
    let url: String
    let lowerSeconds: Double
    let upperSeconds: Double
    let rate: Float
    let rotation: Double
    let isMirror: Bool
    let filterName: String?
    let correction: ColorCorrectionDTO
}

private struct ColorCorrectionDTO: Codable {
    let brightness: Double
    let contrast: Double
    let saturation: Double
}

private extension ClipDTO {
    init(from video: Video) {
        self.url = video.url.absoluteString
        self.lowerSeconds = video.rangeDuration.lowerBound
        self.upperSeconds = video.rangeDuration.upperBound
        self.rate = video.rate
        self.rotation = video.rotation
        self.isMirror = video.isMirror
        self.filterName = video.filterName
        self.correction = .init(
            brightness: video.colorCorrection.brightness,
            contrast: video.colorCorrection.contrast,
            saturation: video.colorCorrection.saturation
        )
    }
}

private extension Video {
    mutating func apply(from dto: ClipDTO) {
        if let u = URL(string: dto.url) {
            self.url = u
        }
        let lower = dto.lowerSeconds
        let upper = dto.upperSeconds
        self.rangeDuration = lower...upper
        self.rate = dto.rate
        self.rotation = dto.rotation
        self.isMirror = dto.isMirror
        self.filterName = dto.filterName
        self.colorCorrection = ColorCorrection(
            brightness: dto.correction.brightness,
            contrast: dto.correction.contrast,
            saturation: dto.correction.saturation
        )
    }
}

class EditorViewModel: ObservableObject {
    
    @Published var clips: [Video] = []
    @Published var selectedClipIndex: Int = 0
    @Published var selectedTools: ToolEnum?
    @Published var frames = VideoFrames()
    @Published var isSelectVideo: Bool = true
    @Published var isPresentingMediaPicker: Bool = false
    
    private var projectEntity: ProjectEntity?
    
    var currentClip: Video? {
        get {
            guard selectedClipIndex < clips.count else { return nil }
            return clips[selectedClipIndex]
        }
        set {
            guard let newValue = newValue else { return }
            guard selectedClipIndex < clips.count else { return }
            clips[selectedClipIndex] = newValue
            updateProject()
        }
    }

    var currentClipBinding: Binding<Video>? {
        guard selectedClipIndex < clips.count else { return nil }
        return Binding<Video>(
            get: { self.clips[self.selectedClipIndex] },
            set: { newValue in
                guard self.selectedClipIndex < self.clips.count else { return }
                self.clips[self.selectedClipIndex] = newValue
                self.updateProject()
            }
        )
    }
    
    // MARK: - Clip Management

    /// Triggers the UI to present a media picker to add another clip.
    func requestAddClip() {
        isPresentingMediaPicker = true
    }
    
    func addClip(_ url: URL, geo: GeometryProxy) {
        print("[EditorVM] addClip url=\(url.absoluteString)")
        var video = Video(url: url)
        video.updateThumbnails(geo)
        clips.append(video)
        selectedClipIndex = clips.count - 1

        if clips.count == 1 {
            createProject()
        } else {
            updateProject()
        }
    }
    
    func removeClip(at index: Int) {
        guard index < clips.count else { return }
        clips.remove(at: index)
        
        if clips.isEmpty {
            selectedClipIndex = 0
        } else if selectedClipIndex >= clips.count {
            selectedClipIndex = clips.count - 1
        }
        
        updateProject()
    }
    
    func moveClip(from source: IndexSet, to destination: Int) {
        clips.move(fromOffsets: source, toOffset: destination)
        updateProject()
    }
    
    func selectClip(at index: Int) {
        guard index < clips.count else { return }
        selectedClipIndex = index
    }
    
    func duplicateClip(at index: Int, geo: GeometryProxy) {
        guard index < clips.count else { return }
        let original = clips[index]
        
        // Create a copy of the video
        var duplicate = Video(url: original.url)
        duplicate.rangeDuration = original.rangeDuration
        duplicate.rate = original.rate
        duplicate.rotation = original.rotation
        duplicate.toolsApplied = original.toolsApplied
        duplicate.filterName = original.filterName
        duplicate.colorCorrection = original.colorCorrection
        duplicate.videoFrames = original.videoFrames
        duplicate.textBoxes = original.textBoxes
        duplicate.audio = original.audio
        duplicate.isMirror = original.isMirror
        duplicate.updateThumbnails(geo)
        
        clips.insert(duplicate, at: index + 1)
        selectedClipIndex = index + 1
        updateProject()
    }
    
    // MARK: - Legacy Support (for single video)
    
    @available(*, deprecated, message: "Use addClip instead")
    func setNewVideo(_ url: URL, geo: GeometryProxy) {
        clips.removeAll()
        addClip(url, geo: geo)
    }
    
    func setProject(_ project: ProjectEntity, geo: GeometryProxy) {
        projectEntity = project
        
        // Check if project has multiple clips stored
        if let clipsData = project.clipsData {
            loadMultipleClips(from: clipsData, geo: geo)
        } else {
            // Legacy single video support
            loadSingleClip(from: project, geo: geo)
        }
    }
    
    private func loadSingleClip(from project: ProjectEntity, geo: GeometryProxy) {
        guard let url = project.videoURL else { return }
        
        let lower = project.lowerBound
        let upper = project.upperBound
        var video = Video(url: url, rangeDuration: lower...upper, rate: Float(project.rate), rotation: project.rotation)
        video.toolsApplied = project.wrappedTools
        video.filterName = project.filterName
        video.colorCorrection = .init(brightness: project.brightness, contrast: project.contrast, saturation: project.saturation)
        var frame = VideoFrames(scaleValue: project.frameScale, frameColor: project.wrappedColor)
        video.videoFrames = frame
        self.frames = frame
        video.updateThumbnails(geo)
        video.textBoxes = project.wrappedTextBoxes
        if let audio = project.audio?.audioModel {
            video.audio = audio
        }
        
        clips = [video]
        selectedClipIndex = 0
    }
    
    private func loadMultipleClips(from data: Data, geo: GeometryProxy) {
        do {
            let decoder = JSONDecoder()
            let dtos = try decoder.decode([ClipDTO].self, from: data)
            var loaded: [Video] = []
            for dto in dtos {
                // Parse URL from persisted string, handling both absolute file URLs and raw paths
                let parsed: URL? = {
                    if let u = URL(string: dto.url), u.scheme != nil {
                        return u
                    } else {
                        return URL(fileURLWithPath: dto.url)
                    }
                }()
                // Resolve within current sandbox if the absolute path is stale
                let resolvedURL: URL = {
                    if let u = parsed, FileManager.default.fileExists(atPath: u.path) {
                        return u
                    }
                    if let u = parsed, let resolved = resolveByFilename(u.lastPathComponent) {
                        return resolved
                    }
                    // As a last resort, keep the parsed (may be /dev/null) to avoid crash; the player will mark as failed
                    return parsed ?? URL(fileURLWithPath: "/dev/null")
                }()

                var video = Video(url: resolvedURL)
                video.apply(from: dto)
                video.updateThumbnails(geo)
                loaded.append(video)
            }
            self.clips = loaded
            // Keep selection in valid bounds
            self.selectedClipIndex = min(self.selectedClipIndex, max(loaded.count - 1, 0))
            // Mirror the selected clip's frames to the VM's frames so overlays/composition stay in sync
            if let first = loaded.first {
                self.frames = first.videoFrames ?? VideoFrames()
            }
        } catch {
            // Fall back to legacy single clip if decoding fails
            self.clips = []
            self.selectedClipIndex = 0
        }
    }

    /// Attempts to resolve a file inside the current app sandbox by its filename
    /// searching common writable locations (Documents, Documents/Videos, Caches, Caches/Videos, tmp).
    private func resolveByFilename(_ filename: String) -> URL? {
        guard !filename.isEmpty else { return nil }
        let fm = FileManager.default
        var candidates: [URL] = []

        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(docs)
            candidates.append(docs.appendingPathComponent("Videos", isDirectory: true))
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            candidates.append(caches)
            candidates.append(caches.appendingPathComponent("Videos", isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))

        for dir in candidates {
            let candidate = dir.appendingPathComponent(filename)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // Exhaustive search (light): enumerate for a direct filename match
        for root in candidates {
            if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let fileURL as URL in e {
                    if fileURL.lastPathComponent == filename, fm.fileExists(atPath: fileURL.path) {
                        return fileURL
                    }
                }
            }
        }
        return nil
    }
    
    // MARK: - Export
    
    func getTotalDuration() -> CMTime {
        var totalSeconds: Double = 0
        for clip in clips {
            let clipSeconds = max(clip.rangeDuration.upperBound - clip.rangeDuration.lowerBound, 0)
            // Protect against divide-by-zero if rate is 0
            let adjusted = clipSeconds / Double(max(clip.rate, 0.0001))
            totalSeconds += adjusted
        }
        return CMTime(seconds: totalSeconds, preferredTimescale: 600)
    }
}

// MARK: - Core data logic
extension EditorViewModel {
    
    private func createProject() {
        guard let firstClip = clips.first else { return }
        let context = PersistenceController.shared.viewContext
        projectEntity = ProjectEntity.create(video: firstClip, context: context)
        updateProject() // Save all clips
    }
     
    func updateProject() {
        guard let projectEntity else { return }

        // Legacy: keep current clip fields in sync for backward compatibility
        if let currentClip = currentClip {
            ProjectEntity.update(for: currentClip, project: projectEntity)
        }

        // Persist all clips
        saveAllClipsToProject(projectEntity)
    }
    
    private func saveAllClipsToProject(_ project: ProjectEntity) {
        let dtos = clips.map { ClipDTO(from: $0) }
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(dtos) {
            project.clipsData = data
            PersistenceController.shared.saveContext()
        }
    }
}

// MARK: - Image to Video helper
extension EditorViewModel {
    /// Creates a temporary H.264 .mp4 video from a `UIImage` with a default 3s duration at 30 fps.
    /// The output size uses the image size, constrained to even dimensions.
    @MainActor
    func makeVideoFromImage(_ image: UIImage, duration: Double = 3.0, fps: Int32 = 30) async throws -> URL {
        let frameCount = Int(Double(fps) * duration)
        guard frameCount > 0 else { throw NSError(domain: "VideoEditor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid duration/fps"]) }

        let size = sanitizeEvenSize(image.size)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: sourceAttributes)

        guard writer.canAdd(input) else { throw NSError(domain: "VideoEditor", code: -2, userInfo: [NSLocalizedDescriptionKey: "Cannot add writer input"]) }
        writer.add(input)

        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "VideoEditor", code: -3, userInfo: [NSLocalizedDescriptionKey: "Start writing failed"]) }
        let timescale: CMTimeScale = fps
        writer.startSession(atSourceTime: .zero)

        // Prepare a resized CGImage once
        guard let cgImage = image.resized(to: size).cgImage else {
            throw NSError(domain: "VideoEditor", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare image"]) }

        let queue = DispatchQueue(label: "image.to.video.writer")
        return try await withCheckedThrowingContinuation { continuation in
            input.requestMediaDataWhenReady(on: queue) {
                var frame = 0
                while input.isReadyForMoreMediaData && frame < frameCount {
                    let presentationTime = CMTime(value: CMTimeValue(frame), timescale: timescale)
                    if let px = cgImage.makePixelBuffer(size: size) {
                        if !adaptor.append(px, withPresentationTime: presentationTime) {
                            input.markAsFinished()
                            writer.cancelWriting()
                            continuation.resume(throwing: writer.error ?? NSError(domain: "VideoEditor", code: -5, userInfo: [NSLocalizedDescriptionKey: "Append failed"]))
                            return
                        }
                    } else {
                        input.markAsFinished()
                        writer.cancelWriting()
                        continuation.resume(throwing: NSError(domain: "VideoEditor", code: -6, userInfo: [NSLocalizedDescriptionKey: "Pixel buffer failed"]))
                        return
                    }
                    frame += 1
                }

                if frame >= frameCount {
                    input.markAsFinished()
                    writer.finishWriting {
                        if writer.status == .completed {
                            continuation.resume(returning: outputURL)
                        } else {
                            continuation.resume(throwing: writer.error ?? NSError(domain: "VideoEditor", code: -7, userInfo: [NSLocalizedDescriptionKey: "Finish failed"]))
                        }
                    }
                }
            }
        }
    }

    private func sanitizeEvenSize(_ size: CGSize) -> CGSize {
        let w = Int(size.width.rounded()) & ~1
        let h = Int(size.height.rounded()) & ~1
        return CGSize(width: max(2, w), height: max(2, h))
    }

    /// Copies a potentially security-scoped URL into the app's temporary directory and returns the new URL.
    /// If the URL is already accessible, it is still copied to ensure local ownership.
    func copyToSandbox(url: URL) throws -> URL {
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)

        var stopAccess = false
        if url.startAccessingSecurityScopedResource() {
            stopAccess = true
        }
        defer {
            if stopAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            print("[EditorVM] copied to sandbox dest=\(dest.path) size=\(size)")
            return dest
        } catch {
            print("[EditorVM][ERR] copyToSandbox failed: \(error)")
            throw error
        }
    }
}

// MARK: - CGImage/UIImage helpers
private extension CGImage {
    func makePixelBuffer(size: CGSize) -> CVPixelBuffer? {
        let options: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var px: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, options as CFDictionary, &px)
        guard status == kCVReturnSuccess, let buffer = px else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) {
            ctx.draw(self, in: CGRect(origin: .zero, size: size))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}

private extension UIImage {
    func resized(to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Tools logic
extension EditorViewModel {
    
    func setFilter(_ filter: String?) {
        currentClip?.setFilter(filter)
        if filter != nil {
            setTools()
        } else {
            removeTool()
        }
    }
    
    func setText(_ textBox: [TextBox]) {
        currentClip?.textBoxes = textBox
        setTools()
    }
    
    func setFrames() {
        currentClip?.videoFrames = frames
        setTools()
    }
    
    func setCorrections(_ correction: ColorCorrection) {
        currentClip?.colorCorrection = correction
        setTools()
    }
    
    func updateRate(rate: Float) {
        currentClip?.updateRate(rate)
        setTools()
    }
    
    func rotate() {
        currentClip?.rotate()
        setTools()
    }
    
    func toggleMirror() {
        currentClip?.isMirror.toggle()
        setTools()
    }
    
    func setAudio(_ audio: Audio) {
        currentClip?.audio = audio
        setTools()
    }
    
    func setTools() {
        guard let selectedTools else { return }
        currentClip?.appliedTool(for: selectedTools)
        updateProject()
    }
    
    func removeTool() {
        guard let selectedTools else { return }
        currentClip?.removeTool(for: selectedTools)
    }
    
    func removeAudio() {
        guard let url = currentClip?.audio?.url else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        currentClip?.audio = nil
        isSelectVideo = true
        removeTool()
        updateProject()
    }
    
    func reset() {
        guard let selectedTools else { return }
        
        switch selectedTools {
        case .trim:
            currentClip?.resetRangeDuration()
        case .speed:
            currentClip?.resetRate()
        case .text, .audio, .crop:
            break
        case .filters:
            currentClip?.setFilter(nil)
        case .corrections:
            currentClip?.colorCorrection = ColorCorrection()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.removeTool()
        }
    }
    
    // Apply tool to all clips
    func applyToAllClips() {
        guard let selectedTools, let currentClip = currentClip else { return }
        
        switch selectedTools {
        case .filters:
            let filter = currentClip.filterName
            for i in clips.indices {
                clips[i].setFilter(filter)
            }
        case .corrections:
            let correction = currentClip.colorCorrection
            for i in clips.indices {
                clips[i].colorCorrection = correction
            }
        case .speed:
            let rate = currentClip.rate
            for i in clips.indices {
                clips[i].updateRate(rate)
            }
        default:
            break
        }
        
        updateProject()
    }
}
