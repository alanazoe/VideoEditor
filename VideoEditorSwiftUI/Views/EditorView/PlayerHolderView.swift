//
//  PlayerHolderView.swift
//  VideoEditorSwiftUI
//
//  Created by Bogdan Zykov on 18.04.2023.
//

import SwiftUI
import PhotosUI
import AVKit

struct PlayerHolderView: View{
    @Binding var isFullScreen: Bool
    @ObservedObject var editorVM: EditorViewModel
    @ObservedObject var videoPlayer: VideoPlayerManager
    @ObservedObject var textEditor: TextEditorViewModel
    var scale: CGFloat{
        isFullScreen ? 1.4 : 1
    }

    var body: some View{
        VStack(spacing: 6) {
            ZStack(alignment: .bottom){
                switch videoPlayer.loadState{
                case .loading:
                    ProgressView()
                case .unknown:
                    Text("Add new video")
                case .failed:
                    Text("Failed to open video")
                case .loaded:
                    playerCropView
                }
            }
            .allFrame()
        }
    }
}

struct PlayerHolderView_Previews: PreviewProvider {
    static var previews: some View {
        MainEditorView()
            .preferredColorScheme(.dark)
    }
}

extension PlayerHolderView{

    private var playerCropView: some View{
        Group{
            if let video = editorVM.currentClip{
                GeometryReader { proxy in
                    CropView(
                        originalSize: .init(width: video.frameSize.width * scale, height: video.frameSize.height * scale),
                        rotation: editorVM.currentClip?.rotation,
                        isMirror: editorVM.currentClip?.isMirror ?? false,
                        isActiveCrop: editorVM.selectedTools == .crop) {
                            ZStack{
                                editorVM.frames.frameColor
                                ZStack {
                                    VideoPlayer(player: videoPlayer.videoPlayer)
                                        .allowsHitTesting(false)
                                        .onDisappear { videoPlayer.pause() }
                                        .id(videoPlayer.videoPlayer.currentItem) // refresh layer when item changes
                                        .frame(width: max(1, proxy.size.width), height: max(1, proxy.size.height)) // ensure non-zero layer size
                                        .background(Color.black) // avoid transparent-zero-sized layer warnings
                                        .clipped()
                                    TextOverlayView(currentTime: videoPlayer.currentTime, viewModel: textEditor, disabledMagnification: isFullScreen)
                                        .scaleEffect(scale)
                                        .disabled(isFullScreen)
                                }
                                .scaleEffect(editorVM.frames.scale)
                            }
                        }
                        .allFrame()
                        .onAppear{
                            Task{
                                guard let size = await editorVM.currentClip?.asset.adjustVideoSize(to: proxy.size) else { return }
                                editorVM.currentClip?.frameSize = size
                                editorVM.currentClip?.geometrySize = proxy.size
                            }
                        }
                        .onChange(of: video.id) { _ in
                            Task {
                                guard let size = await editorVM.currentClip?.asset.adjustVideoSize(to: proxy.size) else { return }
                                editorVM.currentClip?.frameSize = size
                                editorVM.currentClip?.geometrySize = proxy.size
                            }
                        }
                }
                .id(video.id)
            }
            timelineLabel
        }
    }
}

extension PlayerHolderView{
    
    @ViewBuilder
    private var timelineLabel: some View{
        if let video = editorVM.currentClip {
            HStack{
                Text((videoPlayer.currentTime - video.rangeDuration.lowerBound)  .formatterTimeString()) +
                Text(" / ") +
                Text(Int(video.totalDuration).secondsToTime())
            }
            .font(.caption2)
            .foregroundColor(.white)
            .frame(width: 80)
            .padding(5)
            .background(Color(.black).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .padding()
        }
    }
}


struct PlayerControl: View{
    @Binding var isFullScreen: Bool
    @ObservedObject var recorderManager: AudioRecorderManager
    @ObservedObject var editorVM: EditorViewModel
    @ObservedObject var videoPlayer: VideoPlayerManager
    @ObservedObject var textEditor: TextEditorViewModel

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var containerSize: CGSize = .zero

    var body: some View{
        VStack(spacing: 6) {
            playSection
            timeLineControlSection
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerSize = geo.size }
                    .onChange(of: geo.size) { new in containerSize = new }
            
       
        .onChange(of: pickerItems) { newItems in
            guard !newItems.isEmpty else { return }
            
            Task {
                for item in newItems {
                    // First, try loading a direct file URL (common for videos on iOS 17+)
                    if let fileURL = try? await item.loadTransferable(type: URL.self) {
                        // Copy to sandbox to avoid security-scope failures
                        do {
                            let localURL = try await MainActor.run { () -> URL in
                                (try? editorVM.copyToSandbox(url: fileURL)) ?? fileURL
                            }
                            let exists = FileManager.default.fileExists(atPath: localURL.path)
                            let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.intValue ?? -1
                            print("[Picker] imported URL=\(fileURL) -> local=\(localURL), exists=\(exists), size=\(size)")
                            await MainActor.run {
                                editorVM.addClip(localURL, geo: geo)
                                videoPlayer.loadState = .loaded(localURL)
                            }
                        } catch {
                            print("[Picker][ERR] copy to sandbox failed: \(error)")
                        }
                        continue
                    }
                    
                    // Try as movie data
                    if let movieData = try? await item.loadTransferable(type: Data.self) {
                        let tmp = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension("mov")
                        do {
                            try movieData.write(to: tmp, options: .atomic)
                            await MainActor.run {
                                editorVM.addClip(tmp, geo: geo)
                                videoPlayer.loadState = .loaded(tmp)
                            }
                            continue
                        } catch {
                            print("Failed to write temp movie: \(error)")
                        }
                    }
                    
                    // Finally, try loading image data and convert to a video clip
                    if let imageData = try? await item.loadTransferable(type: Data.self), let uiImage = UIImage(data: imageData) {
                        do {
                            let url = try await editorVM.makeVideoFromImage(uiImage)
                            await MainActor.run {
                                editorVM.addClip(url, geo: geo)
                                videoPlayer.loadState = .loaded(url)
                            }
                        } catch {
                            print("Failed to convert image to video: \(error)")
                        }
                        continue
                    }
                }
                
                // Reset picker/sheet on main actor
                await MainActor.run {
                    editorVM.isPresentingMediaPicker = false
                    pickerItems.removeAll()
                }
            }
        }
            }
        )
    }
    
    
    @ViewBuilder
    private var timeLineControlSection: some View{
        VStack(spacing: 8){
            // Clips strip: shows all clips and allows selection by tapping
            if !editorVM.clips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(editorVM.clips.enumerated()), id: \.element.id) { index, clip in
                            let isSelected = index == editorVM.selectedClipIndex
                            ZStack {
                                if let image = clip.thumbnailsImages.first?.image {
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    Color.gray.opacity(0.4)
                                }
                            }
                            .frame(width: 70, height: 50)
                            .clipped()
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2)
                            )
                            .cornerRadius(6)
                            .onTapGesture {
                                editorVM.selectClip(at: index)
                                videoPlayer.loadState = .loaded(clip.url)
                                videoPlayer.setAudio(clip.audio?.url)
                                videoPlayer.scrubState = .scrubEnded(videoPlayer.currentTime)
                            }
                        }
                        PhotosPicker(selection: $pickerItems, matching: .videos) {
                            Image(systemName: "plus.circle.fill")
                                .imageScale(.large)
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add another clip")
                        .padding(.trailing, 4)
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 60)
            }

            HStack {
                if let video = editorVM.currentClip {
                    TimeLineView(
                        recorderManager: recorderManager,
                        currentTime: $videoPlayer.currentTime,
                        isSelectedTrack: $editorVM.isSelectVideo,
                        viewState: editorVM.selectedTools?.timeState ?? .empty,
                        video: video, textInterval: textEditor.selectedTextBox?.timeRange) {
                            videoPlayer.scrubState = .scrubEnded(videoPlayer.currentTime)
                        } onChangeTextTime: { textTime in
                            textEditor.setTime(textTime)
                        } onSetAudio: { audio in
                            editorVM.setAudio(audio)
                            videoPlayer.setAudio(audio.url)
                        }
                }
            }
        }
    }
    
    private var playSection: some View{
        
        Button {
            if let video = editorVM.currentClip{
                videoPlayer.action(video)
            }
        } label: {
            Image(systemName: videoPlayer.isPlaying ? "pause.fill" : "play.fill")
                .imageScale(.medium)
        }
        .buttonStyle(.plain)
        .hCenter()
        .frame(height: 30)
        .overlay(alignment: .trailing) {
            Button {
                videoPlayer.pause()
                withAnimation {
                    isFullScreen.toggle()
                }
            } label: {
                Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }
}
