//
//  VideoPlayerManager.swift
//  VideoEditorSwiftUI
//
//  Created by Bogdan Zykov on 14.04.2023.
//

import Foundation
import Combine
import AVKit
import PhotosUI
import SwiftUI


final class VideoPlayerManager: ObservableObject{
    
    @Published var currentTime: Double = .zero
    @Published var selectedItem: PhotosPickerItem?
    @Published var loadState: LoadState = .unknown
    @Published private(set) var videoPlayer = AVPlayer()
    @Published private(set) var audioPlayer = AVPlayer()
    @Published private(set) var isPlaying: Bool = false
    private var isSetAudio: Bool = false
    private var cancellable = Set<AnyCancellable>()
    private var timeObserver: Any?
    private var currentDurationRange: ClosedRange<Double>?
    private var itemStatusObserver: NSKeyValueObservation?
    
    
    deinit {
        removeTimeObserver()
    }
    
    init(){
        onSubsUrl()
    }
    
    
    var scrubState: PlayerScrubState = .reset {
        didSet {
            switch scrubState {
            case .scrubEnded(let seekTime):
                pause()
                seek(seekTime, player: videoPlayer)
                if isSetAudio{
                    seek(seekTime, player: audioPlayer)
                }
            default : break
            }
        }
    }
    
    func action(_ video: Video){
        self.currentDurationRange = video.rangeDuration
        if isPlaying{
            pause()
        }else{
            play(video.rate)
        }
    }
    
    func setAudio(_ url: URL?){
        guard let url else {
            isSetAudio = false
            return
        }
        audioPlayer = .init(url: url)
        isSetAudio = true
    }
    
    private func onSubsUrl(){
        $loadState
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] returnLoadState in
                guard let self = self else { return }

                switch returnLoadState {
                case .loaded(let url):
                    print("[VideoPlayer] loadState .loaded URL=\(url.absoluteString)")

                    // Quick sanity checks on the file before handing to AVFoundation.
                    let path = url.path
                    let exists = FileManager.default.fileExists(atPath: path)
                    var sizeDesc = "unknown"
                    if exists {
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                           let size = attrs[.size] as? NSNumber {
                            sizeDesc = "\(size.intValue) bytes"
                        }
                    }
                    print("[VideoPlayer] file exists=\(exists) size=\(sizeDesc)")

                    // If the saved absolute path is stale (e.g., app reinstalled; different container),
                    // try to resolve the file by filename within the current sandbox.
                    let finalURL: URL
                    if !exists {
                        if let resolved = self.resolvePlayableURL(url) {
                            print("[VideoPlayer][RESOLVE] Remapped stale path to current container: \(resolved.path)")
                            finalURL = resolved
                        } else {
                            print("[VideoPlayer][RESOLVE][ERR] Could not resolve file: \(url.lastPathComponent)")
                            self.loadState = .failed
                            return
                        }
                    } else {
                        finalURL = url
                    }

                    self.preparePlayer(with: finalURL)

                case .failed, .loading, .unknown:
                    break
                }
            }
            .store(in: &cancellable)
    }
    
    private func preparePlayer(with url: URL) {
        // Pause current playback and remove old observers
        pause()
        removeTimeObserver()

        // Build an AVURLAsset and load the critical keys we need.
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        let keys = ["playable", "duration", "tracks", "hasProtectedContent"]
        asset.loadValuesAsynchronously(forKeys: keys) { [weak self] in
            guard let self = self else { return }

            var error: NSError?
            let playableStatus = asset.statusOfValue(forKey: "playable", error: &error)
            let durationStatus = asset.statusOfValue(forKey: "duration", error: nil)
            let tracksStatus = asset.statusOfValue(forKey: "tracks", error: nil)

            DispatchQueue.main.async {
                if let error = error {
                    print("[VideoPlayer][ASSET][ERR] loadValues error=\(error)")
                }
                // Guard against common failure cases
                if playableStatus != .loaded || !asset.isPlayable || asset.hasProtectedContent {
                    print("[VideoPlayer][ASSET][ERR] not playable. playableStatus=\(playableStatus.rawValue) isPlayable=\(asset.isPlayable) hasProtectedContent=\(asset.hasProtectedContent)")
                    self.loadState = .failed
                    return
                }
                if durationStatus != .loaded || tracksStatus != .loaded {
                    print("[VideoPlayer][ASSET][WARN] durationStatus=\(durationStatus.rawValue) tracksStatus=\(tracksStatus.rawValue)")
                }

                // Create a fresh item from the validated asset and observe readiness
                let item = AVPlayerItem(asset: asset)
                self.itemStatusObserver?.invalidate()
                self.videoPlayer.replaceCurrentItem(with: item)
                self.videoPlayer.automaticallyWaitsToMinimizeStalling = true

                self.startStatusSubscriptions()

                if let currentItem = self.videoPlayer.currentItem {
                    self.observeItemStatus(currentItem)
                    print("[VideoPlayer] currentItem duration=\(currentItem.asset.duration.seconds)")
                } else {
                    print("[VideoPlayer][WARN] currentItem is nil after replaceCurrentItem")
                }
            }
        }
    }
    
    /// Attempts to resolve a stale file URL (from an old sandbox container) by matching on the filename
    /// within known writable directories of the current app (Documents, Library/Caches, tmp, and an optional "Videos" folder).
    private func resolvePlayableURL(_ staleURL: URL) -> URL? {
        let filename = staleURL.lastPathComponent
        guard !filename.isEmpty else { return nil }

        let fm = FileManager.default
        var candidates: [URL] = []

        // Documents
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(docs)
            candidates.append(docs.appendingPathComponent("Videos", isDirectory: true))
        }
        // Library/Caches
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            candidates.append(caches)
            candidates.append(caches.appendingPathComponent("Videos", isDirectory: true))
        }
        // tmp
        candidates.append(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))

        for dir in candidates {
            let candidate = dir.appendingPathComponent(filename)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // As a last resort, try to locate by enumerating Documents and Caches for matching filenames.
        let searchRoots = candidates
        for root in searchRoots {
            if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let fileURL as URL in enumerator {
                    if fileURL.lastPathComponent == filename, fm.fileExists(atPath: fileURL.path) {
                        return fileURL
                    }
                }
            }
        }
        return nil
    }
    
    
    private func startStatusSubscriptions(){
        print("[VideoPlayer] startStatusSubscriptions")
        videoPlayer.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                guard let self = self else {return}
                switch status {
                case .playing:
                    print("[VideoPlayer] timeControlStatus=playing, rate=\(self.videoPlayer.rate)")
                    self.isPlaying = true
                    self.startTimer()
                case .paused:
                    print("[VideoPlayer] timeControlStatus=paused")
                    self.isPlaying = false
                case .waitingToPlayAtSpecifiedRate:
                    print("[VideoPlayer] timeControlStatus=waitingToPlayAtSpecifiedRate")
                @unknown default:
                    print("[VideoPlayer][WARN] timeControlStatus unknown")
                }
            }
            .store(in: &cancellable)

        // Also observe currentItem status via KVO to know when it's ready
        if let item = videoPlayer.currentItem {
            observeItemStatus(item)
        }
    }
    
    
    func pause(){
        print("[VideoPlayer] pause() isPlaying=\(isPlaying)")
        if isPlaying{
            videoPlayer.pause()
            if isSetAudio{
                audioPlayer.pause()
            }
        }
    }
    
    func setVolume(_ isVideo: Bool, value: Float){
        pause()
        if isVideo{
            videoPlayer.volume = value
        }else{
            audioPlayer.volume = value
        }
    }

    private func play(_ rate: Float?){
        print("[VideoPlayer] play(rate=\(String(describing: rate))) currentTime=\(videoPlayer.currentTime().seconds)")
        AVAudioSession.sharedInstance().configurePlaybackSession()
        
        if let currentDurationRange{
            if currentTime >= currentDurationRange.upperBound{
                print("[VideoPlayer] seek to lowerBound=\(currentDurationRange.lowerBound)")
                seek(currentDurationRange.lowerBound, player: videoPlayer)
                if isSetAudio{
                    seek(currentDurationRange.lowerBound, player: audioPlayer)
                }
            }else{
                print("[VideoPlayer] resume seek to current video time=\(videoPlayer.currentTime().seconds)")
                seek(videoPlayer.currentTime().seconds, player: videoPlayer)
                if isSetAudio{
                    seek(audioPlayer.currentTime().seconds, player: audioPlayer)
                }
            }
        }
        videoPlayer.play()
        if isSetAudio{
            audioPlayer.play()
        }
        
        if let rate{
            videoPlayer.rate = rate
            if isSetAudio{
                audioPlayer.play()
            }
            print("[VideoPlayer] set rate=\(rate)")
        }
        
        if let currentDurationRange, videoPlayer.currentItem?.duration.seconds ?? 0 >= currentDurationRange.upperBound{
            NotificationCenter.default.addObserver(forName: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: videoPlayer.currentItem, queue: .main) { _ in
                self.playerDidFinishPlaying()
            }
        }
    }
    
    private func seek(_ seconds: Double, player: AVPlayer){
        print("[VideoPlayer] seek(to=\(seconds)) for \(player === videoPlayer ? "video" : "audio")")
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }
    
    private func startTimer() {
        
        let interval = CMTimeMake(value: 1, timescale: 10)
        timeObserver = videoPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            if self.isPlaying{
                let time = time.seconds
                
                if let currentDurationRange = self.currentDurationRange, time >= currentDurationRange.upperBound{
                    self.pause()
                }

                switch self.scrubState {
                case .reset:
                    self.currentTime = time
                case .scrubEnded:
                    self.scrubState = .reset
                case .scrubStarted:
                    break
                }
            }
        }
    }
    
    
    private func playerDidFinishPlaying() {
        print("[VideoPlayer] didPlayToEnd -> seek to zero")
        self.videoPlayer.seek(to: .zero)
    }
    
    private func removeTimeObserver(){
        if let timeObserver = timeObserver {
            videoPlayer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }
    
}

// MARK: - KVO for item readiness
private extension VideoPlayerManager {
    func observeItemStatus(_ item: AVPlayerItem) {
        itemStatusObserver?.invalidate()
        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, change in
            guard let self = self else { return }
            switch item.status {
            case .unknown:
                print("[VideoPlayer][ITEM] status=unknown")
            case .readyToPlay:
                print("[VideoPlayer][ITEM] status=readyToPlay, duration=\(item.duration.seconds)")
                // Seek to 0 so the first frame is rendered
                self.seek(0, player: self.videoPlayer)
            case .failed:
                print("[VideoPlayer][ITEM][ERR] status=failed: \(String(describing: item.error))")
            @unknown default:
                print("[VideoPlayer][ITEM][WARN] status unknown")
            }
        }
    }
}

extension VideoPlayerManager{
    
    @MainActor
    func loadVideoItem(_ selectedItem: PhotosPickerItem?) async{
        do {
            loadState = .loading

            if let video = try await selectedItem?.loadTransferable(type: VideoItem.self) {
                print("[VideoPlayer] loadVideoItem loaded URL=\(video.url)")
                loadState = .loaded(video.url)
            } else {
                print("[VideoPlayer][ERR] loadVideoItem failed: no video transferable")
                loadState = .failed
            }
        } catch {
            print("[VideoPlayer][ERR] loadVideoItem exception: \(error)")
            loadState = .failed
        }
    }
}


extension VideoPlayerManager{
    

    func setFilters(mainFilter: CIFilter?, colorCorrection: ColorCorrection?){
        guard videoPlayer.currentItem != nil else {
            print("[VideoPlayer][FILTERS][SKIP] No currentItem yet")
            return
        }
       
        let filters = Helpers.createFilters(mainFilter: mainFilter, colorCorrection)
        
        if filters.isEmpty{
            return
        }
        self.pause()
        DispatchQueue.global(qos: .userInteractive).async {
            let composition = self.videoPlayer.currentItem?.asset.setFilters(filters)
            self.videoPlayer.currentItem?.videoComposition = composition
            print("[VideoPlayer] filters applied: count=\(filters.count)")
        }
    }
        
    func removeFilter(){
        pause()
        videoPlayer.currentItem?.videoComposition = nil
        print("[VideoPlayer] filters removed")
    }
}

enum LoadState: Identifiable, Equatable {
    case unknown, loading, loaded(URL), failed
    
    var id: Int{
        switch self {
        case .unknown: return 0
        case .loading: return 1
        case .loaded: return 2
        case .failed: return 3
        }
    }
}


enum PlayerScrubState{
    case reset
    case scrubStarted
    case scrubEnded(Double)
}


extension AVAsset{
    
    func setFilter(_ filter: CIFilter) -> AVVideoComposition{
        let composition = AVVideoComposition(asset: self, applyingCIFiltersWithHandler: { request in
            filter.setValue(request.sourceImage, forKey: kCIInputImageKey)
            
            guard let output = filter.outputImage else {return}
            
            request.finish(with: output, context: nil)
        })
        
        return composition
    }
    
    func setFilters(_ filters: [CIFilter]) -> AVVideoComposition{
        let composition = AVVideoComposition(asset: self, applyingCIFiltersWithHandler: { request in
            
            let source = request.sourceImage
            var output = source
            
            filters.forEach { filter in
                filter.setValue(output, forKey: kCIInputImageKey)
                if let image = filter.outputImage{
                    output = image
                }
            }
            
            request.finish(with: output, context: nil)
        })
        
        return composition
    }

}
