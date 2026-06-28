//
//  VoiceNoteBubble.swift
//  Screens
//
//  The interactive content of a voice-note bubble: a play/pause control, a
//  real waveform (bars derived from the clip's PCM), and a duration readout.
//
//  The waveform fills left-to-right as playback advances — played bars in
//  brand color, the rest muted — and a tap or drag along it seeks. The bars
//  are extracted off the main actor on first appearance; until they land, a
//  faint flat line stands in.
//
//  MessageRow owns the bubble's shape + background; this view only renders
//  the controls inside it, so the tail geometry stays a single source of
//  truth.
//

import SwiftUI

struct VoiceNoteBubble: View {

    let data: Data
    let isOutbound: Bool

    @State private var player: VoicePlayer
    @State private var bars: [CGFloat]
    @State private var didLoadBars = false

    // MARK: - Spec constants

    private static let barCount = 30
    private static let barWidth: CGFloat = 2
    private static let barSpacing: CGFloat = 2
    private static let minBarHeight: CGFloat = 2
    private static let waveformWidth: CGFloat = 130
    private static let waveformHeight: CGFloat = 26
    private static let playSize: CGFloat = 34

    init(data: Data, isOutbound: Bool) {
        self.data = data
        self.isOutbound = isOutbound
        _player = State(initialValue: VoicePlayer(data: data))
        _bars = State(initialValue: Array(repeating: 0.12, count: Self.barCount))
    }

    var body: some View {
        HStack(spacing: 10) {
            playButton
            waveform
            timeLabel
        }
        .task { await loadBars() }
    }

    // MARK: - Play / pause

    private var playButton: some View {
        Button { player.toggle() } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Self.playSize, height: Self.playSize)
                .background(Circle().fill(Color.brand))
        }
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    // MARK: - Waveform

    private var waveform: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: Self.barSpacing) {
                ForEach(bars.indices, id: \.self) { index in
                    Capsule()
                        .fill(color(for: index))
                        .frame(width: Self.barWidth,
                               height: max(Self.minBarHeight,
                                           bars[index] * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(seekGesture(width: geo.size.width))
        }
        .frame(width: Self.waveformWidth, height: Self.waveformHeight)
    }

    /// Bar is "played" once playback has passed its position.
    private func color(for index: Int) -> Color {
        let fraction = bars.isEmpty ? 0 : Double(index) / Double(bars.count)
        return fraction <= player.progress ? Color.brand : unplayedColor
    }

    private var unplayedColor: Color {
        isOutbound ? Color.bubbleOutText.opacity(0.35)
                   : Color.bubbleInText.opacity(0.35)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        // minimumDistance 0 → a plain tap also seeks; a drag scrubs.
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                let fraction = width > 0 ? value.location.x / width : 0
                player.seek(to: Double(fraction))
            }
    }

    // MARK: - Time

    private var timeLabel: some View {
        Text(timeString)
            .font(Typography.deliveryChip)
            .monospacedDigit()
            .foregroundStyle(isOutbound ? Color.bubbleOutText
                                        : Color.bubbleInText)
    }

    /// Elapsed while playing or scrubbed; total duration when idle at the start.
    private var timeString: String {
        let seconds = player.progress > 0
            ? player.progress * player.duration
            : player.duration
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Loading

    private func loadBars() async {
        guard !didLoadBars else { return }
        let blob = data
        let count = Self.barCount
        let computed = await Task.detached {
            WaveformExtractor.bars(from: blob, count: count)
        }.value
        bars = computed
        didLoadBars = true
    }
}
