import SwiftUI
import ScarlettCore

/// A vertical mixer strip for one matrix channel in the currently selected bus.
/// Layout mirrors Focusrite Control 2: name + source + colored underline at top,
/// fader with dB scale and meter in the middle, M/S buttons at the bottom.
///
/// When `channel` is the left (even) half of a linked pair, the strip drives
/// both channels as one stereo strip: paired source picker, L/R meter, a
/// stereo pan, and shared fader / mute / solo.  The mixer hides the right
/// channel's own strip while linked.
@MainActor
struct ChannelStrip: View {
    let channel: Int
    @Bindable var state: MixerState
    @Environment(\.faderHeight) private var faderHeight
    @State private var editingName: Bool = false
    @State private var nameDraft: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let source = state.mixerSources[channel]
        let isMuted = state.mixerMutes[channel]
        let isSoloed = state.mixerSolos[channel]

        VStack(spacing: StripLayout.vSpacing) {
            header(source: source)
            inputSwitch(source: source)
                .frame(height: StripLayout.switchRowHeight)
            panSlider
                .frame(height: StripLayout.panRowHeight)
            fader
                .frame(height: faderHeight)
            peakReadout
                .frame(height: StripLayout.peakReadoutHeight)
            mutesolo(isMuted: isMuted, isSoloed: isSoloed)
                .frame(height: StripLayout.controlsHeight)
        }
        .frame(width: StripLayout.width)
        .padding(.vertical, StripLayout.cardPaddingV)
        .padding(.horizontal, 6)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// True when this strip stands for a linked stereo pair.
    private var isStereo: Bool { state.isLinked(channel) && channel % 2 == 0 }
    private var rightChannel: Int { channel + 1 }

    // MARK: - Contextual hardware-input switch
    //
    // When this strip's source is one of the device's software-configurable
    // hardware inputs (per profile.impedanceChannels / hiLoChannels), surface
    // the relevant switch right here on the strip
    // so the user doesn't have to navigate elsewhere.  Otherwise reserve
    // the same vertical space (an empty placeholder) to keep strip heights
    // consistent across the row.

    @ViewBuilder
    private func inputSwitch(source: SignalSource) -> some View {
        // A stereo strip's switch sets both inputs of the pair (shown from
        // the left one), so Analog 1/2 flips both to Line or Inst together.
        let pairSources: Set<SignalSource> = isStereo
            ? [source, state.mixerSources[rightChannel]] : [source]
        let impedanceChannels = [(SignalSource.analog1, 1), (.analog2, 2)]
            .filter { pairSources.contains($0.0) }.map(\.1)
        let hiLoChannels = [(SignalSource.analog3, 3), (.analog4, 4)]
            .filter { pairSources.contains($0.0) }.map(\.1)
        if let first = impedanceChannels.first {
            ImpedanceSwitch(value: Binding(
                get: { first == 1 ? state.impedance1 : state.impedance2 },
                set: { mode in impedanceChannels.forEach { state.userSetImpedance(channel: $0, mode: mode) } }
            ))
        } else if let first = hiLoChannels.first {
            HiLoSwitch(value: Binding(
                get: { first == 3 ? state.hi3 : state.hi4 },
                set: { hi in hiLoChannels.forEach { state.userSetHiLo(channel: $0, hi: hi) } }
            ))
        } else {
            // Reserve the same vertical footprint so every strip aligns.
            Color.clear.frame(height: 22)
        }
    }

    // MARK: - Header

    private func header(source: SignalSource) -> some View {
        VStack(spacing: 3) {
            nameField
            Spacer(minLength: 0)
            if isStereo {
                ThemedMenuPicker(
                    options: state.stereoSourceOptions,
                    displayName: { $0.displayName },
                    selection: Binding(
                        get: { StereoSource(left: state.mixerSources[channel],
                                            right: state.mixerSources[rightChannel]) },
                        set: { state.userSetStereoSource(leftChannel: channel, $0) }
                    )
                )
            } else {
                ThemedMenuPicker(
                    options: state.matrixSourceOptions,
                    displayName: { $0.displayName },
                    selection: Binding(
                        get: { state.mixerSources[channel] },
                        set: { state.userSetMixerSource(channel: channel, source: $0) }
                    )
                )
            }

            Rectangle()
                .fill(source.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 2)
        }
        // Fixed like the pinned strips' headers, so the rows below line up.
        .frame(height: StripLayout.headerHeight, alignment: .bottom)
    }

    /// Channel name — defaults to "Ch N" ("Ch N/Ch N+1" for a stereo
    /// strip), double-click to rename.
    private var nameField: some View {
        let stored = state.mixerNames[channel]
        let displayed = isStereo
            ? state.stereoDisplayName(leftChannel: channel)
            : (stored.isEmpty ? "Ch \(channel + 1)" : stored)
        return Group {
            if editingName {
                TextField("Name", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .focused($nameFocused)
                    .onSubmit { commitName() }
                    .onExitCommand { editingName = false }
                    .onAppear {
                        nameDraft = stored
                        nameFocused = true
                    }
            } else {
                Text(displayed)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        nameDraft = stored
                        editingName = true
                    }
                    .help("Double-click to rename")
            }
        }
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        if isStereo {
            state.userSetStereoName(leftChannel: channel, name: trimmed)
        } else {
            state.userSetChannelName(channel: channel, name: trimmed)
        }
        editingName = false
    }

    // MARK: - Fader column

    private var fader: some View {
        let pair = MixerState.pairIndex(of: state.selectedBus)
        let level = faderLevel(pair: pair)
        let source = state.mixerSources[channel]

        return HStack(alignment: .center, spacing: 4) {
            VerticalFader(db: Binding(
                get: { level },
                set: { setLevel($0, pair: pair) }
            ))
            .opacity(state.mixerMutes[channel] ? 0.4 : 1.0)
            .contextMenu {
                Button("Reset fader to 0 dB") { setLevel(0, pair: pair) }
            }

            // Reads peaks/peaksHeld/peaksMax internally → isolated from the
            // outer strip body so 20 Hz meter updates only re-render this
            // small view, not the whole strip (faders, pickers, buttons, …).
            if isStereo {
                // L and R bars side by side, split by a thin black line.
                HStack(spacing: 0) {
                    StripMeter(state: state, source: source, profile: state.profile)
                    Rectangle().fill(Color.black).frame(width: 1)
                    StripMeter(state: state, source: state.mixerSources[rightChannel],
                               profile: state.profile)
                }
            } else {
                StripMeter(state: state, source: source, profile: state.profile)
            }

            DbScale()
        }
        .frame(height: faderHeight)
    }

    /// The fader's level (a stereo strip's covers both channels).
    private func faderLevel(pair: Int) -> Double {
        isStereo ? state.stereoLevel(leftChannel: channel, pair: pair)
                 : state.mixerLevels[channel][pair]
    }

    private func setLevel(_ db: Double, pair: Int) {
        if isStereo {
            state.userSetStereoLevel(leftChannel: channel, pair: pair, level: db)
        } else {
            state.userSetMixerLevel(channel: channel, pair: pair, level: db)
        }
    }

    /// Pan on a mono strip.  A stereo strip has none — the pair stays hard
    /// L/R — so it reserves the row's space to keep strips aligned.
    @ViewBuilder
    private var panSlider: some View {
        if isStereo {
            Color.clear
        } else {
            let pair = MixerState.pairIndex(of: state.selectedBus)
            let pan = state.mixerPans[channel][pair]
            VStack(spacing: 1) {
                Slider(
                    value: Binding(
                        get: { pan },
                        set: { state.userSetMixerPan(channel: channel, pair: pair, pan: $0) }
                    ),
                    in: -1...1
                )
                .controlSize(.mini)
                .contextMenu {
                    Button("Reset pan to center") {
                        state.userSetMixerPan(channel: channel, pair: pair, pan: 0)
                    }
                }
                Text(panLabel(pan))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func panLabel(_ pan: Double) -> String {
        if abs(pan) < 0.02 { return "C" }
        let pct = Int(round(abs(pan) * 100))
        return pan < 0 ? "L\(pct)" : "R\(pct)"
    }

    private var peakReadout: some View {
        let sources = isStereo
            ? [state.mixerSources[channel], state.mixerSources[rightChannel]]
            : [state.mixerSources[channel]]
        let pair = MixerState.pairIndex(of: state.selectedBus)
        return StripReadout(
            state: state,
            faderDb: faderLevel(pair: pair),
            faderMuted: state.mixerMutes[channel],
            // A stereo strip shows the louder side's max peak.
            maxPeak: { s in
                sources.map { StripMeter.level(from: s.peaksMax, source: $0, profile: s.profile) }
                    .max() ?? -.infinity
            },
            resetHelp: isStereo ? "Click to reset this pair's max peaks" : "Click to reset this channel's max peak"
        ) { sources.forEach { state.clearMaxPeak(forSource: $0) } }
    }

    // MARK: - Mute / Solo

    private func mutesolo(isMuted: Bool, isSoloed: Bool) -> some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            StripButton(letter: "M", active: isMuted, activeColor: Theme.muteActive) {
                state.userToggleMixerMute(channel: channel)
            }
            StripButton(letter: "S", active: isSoloed, activeColor: Theme.soloActive) {
                state.userToggleMixerSolo(channel: channel)
            }
            LinkButton(active: state.isLinked(channel)) {
                state.userToggleLink(channel: channel)
            }
            Spacer(minLength: 0)
        }
    }

}

/// Compact Line/Instrument toggle for the combo-input strips (Analog 1, 2).
struct ImpedanceSwitch: View {
    @Binding var value: Impedance

    var body: some View {
        Picker("", selection: $value) {
            Text("Line").tag(Impedance.line)
            Text("Inst").tag(Impedance.instrument)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .frame(height: 22)
    }
}

/// Compact Lo/Hi gain toggle for the line-input strips (Analog 3, 4).
struct HiLoSwitch: View {
    @Binding var value: Bool

    var body: some View {
        Picker("", selection: $value) {
            Text("Lo").tag(false)
            Text("Hi").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .frame(height: 22)
    }
}

/// Live + peak-hold + max meter for one strip.  Isolated into its own struct
/// so that 20 Hz `peaks*` updates only re-render this view, not the parent
/// strip's fader / pickers / buttons / name field.
@MainActor
struct StripMeter: View {
    @Bindable var state: MixerState
    let source: SignalSource
    let profile: DeviceProfile

    var body: some View {
        let live = Self.level(from: state.peaks, source: source, profile: profile)
        let held = Self.level(from: state.peaksHeld, source: source, profile: profile)
        let max_ = Self.level(from: state.peaksMax, source: source, profile: profile)
        VerticalMeter(db: live, peakDb: held, maxPeakDb: max_)
    }

    static func level(from peaks: PeakReading, source: SignalSource, profile: DeviceProfile) -> Double {
        let bus = MixBus(rawValue: source.rawValue) ?? .off
        return peaks.level(for: bus, profile: profile)
    }
}

/// The strip's readout row, DAW style: the fader's level on the left (under
/// the fader) and the meter's max peak since the last reset on the right
/// (under the meter).  Click the max peak to reset it; at full scale it
/// reads "CLIP" in red, held until the reset.  Reads the peaks itself, so
/// 20 Hz meter updates re-render only this row, not the whole strip.
@MainActor
struct StripReadout: View {
    @Bindable var state: MixerState
    /// The fader's level, or nil for an output without a fader.
    let faderDb: Double?
    var faderMuted = false
    /// The max peak to show, read from `state` (louder side of a pair).
    let maxPeak: (MixerState) -> Double
    let resetHelp: String
    let reset: () -> Void

    var body: some View {
        let peak = maxPeak(state)
        HStack(spacing: 2) {
            // Cubase-style contrast: the fader level bright, the peak dimmer.
            cell(faderDb.map(DbAxis.format) ?? "",
                 color: faderMuted ? Theme.muteActive : Theme.textPrimary)
            Button(action: reset) {
                cell(DbAxis.formatPeak(peak),
                     color: peak >= DbAxis.clip ? Theme.failure : Theme.textSecondary.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(resetHelp)
        }
    }

    private func cell(_ text: String, color: Color) -> some View {
        ReadoutCell(text: text, color: color)
    }
}

/// One field of a level / peak readout: monospaced figures on a dark
/// inset — the mixer strips' readout row and the menu bar panel.
struct ReadoutCell: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.readoutField)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .contentShape(Rectangle())
    }
}

/// Small button shown on each strip — toggles whether this channel is in a
/// linked stereo pair with its even/odd partner.  Active = paired.
struct LinkButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "link")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(active ? Theme.accent : Theme.panelRaised)
                .foregroundStyle(active ? .white : Theme.textSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(active ? "Linked stereo pair (click to unlink)" : "Link with adjacent channel")
        .accessibilityLabel(active ? "Unlink stereo pair" : "Link with adjacent channel")
    }
}

struct StripButton: View {
    let letter: String
    let active: Bool
    let activeColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(letter)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 26, height: 22)
                .background(active ? activeColor : Theme.panelRaised)
                .foregroundStyle(active ? .white : Theme.textSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }
}
