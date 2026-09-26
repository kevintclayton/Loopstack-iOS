import CoreAudioKit
import SwiftUI
import UIKit

struct StudioView: View {
  @StateObject private var engine = LoopEngine()
  /// Stack (the live loopstack) or Song (the arranged blocks).
  @State private var showSong = false
  /// Regular width (iPad, full screen) gets the two-column layout.
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    ZStack {
      LS.bg.ignoresSafeArea()
      if engine.unlocked {
        desk
          .background(HardwareTypingView(
            onDown: { engine.typingDown($0) },
            onUp: { engine.typingUp($0) }
          ))
      } else {
        GateView { engine.unlock() }
      }
    }
    .preferredColorScheme(.dark)
    #if DEBUG
    .task {
      // Screenshot demo: launch with `-demo stack|keys|loops|drums|song`.
      if let scene = UserDefaults.standard.string(forKey: "demo") { engine.loadDemo(scene) }
    }
    #endif
  }

  /// Two columns need about 900 points: every iPad in landscape, the 13" in portrait.
  /// Narrower (smaller iPads upright, Split View) gets the single column; on iPad it's
  /// centred at a comfortable width.
  private static let twoColumnWidth: CGFloat = 900

  private var desk: some View {
    GeometryReader { geo in
      if sizeClass == .regular && geo.size.width >= Self.twoColumnWidth {
        IPadDesk(engine: engine, showSong: $showSong, header: header, modeSwitch: modeSwitch, exportRow: exportRow)
          #if DEBUG
          .onAppear { if engine.demoScene == "song" { showSong = true } }
          .onChange(of: engine.demoScene) { showSong = $0 == "song" }
          #endif
      } else {
        phoneDesk
          .frame(maxWidth: sizeClass == .regular ? 720 : .infinity)
          .frame(maxWidth: .infinity)
      }
    }
  }

  /// iPhone (and narrow iPad windows): one scrolling column.
  private var phoneDesk: some View {
    ScrollViewReader { proxy in
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        modeSwitch
        if showSong {
          SongView(engine: engine, backToStack: { showSong = false })
        } else {
          TransportView(engine: engine, openSong: { showSong = true })
          InstrumentView(engine: engine).id("keys")
          LayersView(engine: engine).id("loops")
          DrumsView(engine: engine).id("drums")
          MixView(engine: engine).id("mix")
          SessionView(engine: engine, share: { SharePresenter.present($0) })
          exportRow
        }
        PrivacyView()
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 40)
    }
    #if DEBUG
    // The demo sets its scene as it opens the studio, so apply it on appear too.
    .onAppear { showDemo(engine.demoScene, proxy) }
    .onChange(of: engine.demoScene) { showDemo($0, proxy) }
    #endif
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("STUDIO LOOPER")
        .font(.system(size: 11, weight: .medium, design: .default))
        .tracking(2.4)
        .foregroundStyle(LS.subtle)
      Text("Loopstack")
        .font(.system(size: 32, weight: .semibold))
        .foregroundStyle(LS.fg)
    }
  }

  #if DEBUG
  private func showDemo(_ scene: String?, _ proxy: ScrollViewProxy) {
    guard let scene else { return }
    showSong = scene == "song"
    let target: [String: String] = [
      "keys": "keys", "chords": "keys", "synth": "synthpanel", "loops": "loops", "reverse": "loops",
      "drums": "drums", "neon": "drums", "mix": "mix",
    ]
    if let id = target[scene] {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { proxy.scrollTo(id, anchor: .top) }
    }
  }
  #endif

  /// Stack | Song. Both keep their state; switching only changes what's on screen.
  private var modeSwitch: some View {
    HStack(spacing: 6) {
      pill("Stack", on: !showSong) { showSong = false }
      pill(engine.songBlocks.isEmpty ? "Song" : "Song · \(engine.songBlocks.count)", on: showSong) { showSong = true }
      Spacer()
      if engine.songPlaying && !showSong {
        Text("Song playing")
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(LS.accent)
      }
    }
  }

  private var exportRow: some View {
    Button {
      if let url = engine.exportStems() { SharePresenter.present(url) }
    } label: {
      Text(engine.layers.isEmpty && !engine.drumsOn ? "Export loops as stems" : "Share stems")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(engine.layers.isEmpty && !engine.drumsOn ? LS.subtle.opacity(0.5) : LS.subtle)
    }
    .disabled(engine.layers.isEmpty && !engine.drumsOn)
    .frame(maxWidth: .infinity)
  }
}

struct GateView: View {
  var onStart: () -> Void
  var body: some View {
    VStack(spacing: 0) {
      Spacer()
      Text("AUDIO ROOM")
        .font(.system(size: 11, weight: .medium))
        .tracking(3)
        .foregroundStyle(LS.subtle)
      Text("Loopstack")
        .font(.system(size: 52, weight: .semibold))
        .foregroundStyle(LS.fg)
        .padding(.top, 10)
      LoopstackMark()
        .frame(width: 168, height: 72)
        .padding(.top, 28)
        .allowsHitTesting(false)
      Button(action: onStart) {
        Text("Tap to open")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(LS.bg)
          .frame(height: 48)
          .padding(.horizontal, 32)
          .background(LS.fg, in: Capsule())
      }
      .buttonStyle(.plain)
      .padding(.top, 28)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onTapGesture(perform: onStart)
    .padding(24)
  }
}

struct LoopstackMark: View {
  @State private var playhead: CGFloat = 0
  private let width: CGFloat = 168
  private let height: CGFloat = 72
  var body: some View {
    let barH: CGFloat = 13
    let gap: CGFloat = 8
    ZStack(alignment: .leading) {
      VStack(spacing: gap) {
        Capsule().fill(LS.accent.opacity(0.85)).frame(height: barH)
        Capsule().fill(LS.fg.opacity(0.9)).frame(height: barH)
        Capsule().fill(LS.accent.opacity(0.7)).frame(height: barH)
      }
      Capsule()
        .fill(LS.record)
        .frame(width: 5, height: height)
        .offset(x: 8 + playhead * (width - 21))
    }
    .frame(width: width, height: height)
    .onAppear {
      withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
        playhead = 1
      }
    }
  }
}

struct TransportView: View {
  @ObservedObject var engine: LoopEngine
  var openSong: () -> Void = {}
  @State private var taps: [TimeInterval] = []

  var body: some View {
    card {
      HStack(alignment: .bottom) {
        VStack(alignment: .leading, spacing: 4) {
          Text(statusText)
            .font(.system(size: 11, weight: .medium))
            .tracking(2)
            .foregroundStyle(LS.subtle)
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(engine.bpm)")
              .font(.system(size: 34, weight: .regular, design: .monospaced))
              .foregroundStyle(LS.fg)
            Text("BPM")
              .font(.system(size: 14, weight: .medium))
              .foregroundStyle(LS.muted)
          }
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 4) {
          Text(engine.running ? barLabel : "\(engine.bars) bars")
            .font(.system(size: 14, design: .monospaced))
            .foregroundStyle(LS.muted)
          Text(String(format: "%.1fs", engine.loopDuration))
            .font(.system(size: 18, design: .monospaced))
            .foregroundStyle(LS.fg)
          if engine.sessionRecording {
            Text(String(format: "Session %d:%02d", Int(engine.sessionElapsed) / 60, Int(engine.sessionElapsed) % 60))
              .font(.system(size: 12, design: .monospaced))
              .foregroundStyle(LS.record)
          }
        }
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(InstrumentPreset.allCases) { p in
            pill(p.label, on: engine.preset == p && engine.acousticId == nil) { engine.setPreset(p) }
          }
        }
      }

      LoopRuler(position: engine.position, recording: engine.recording, running: engine.running, bars: min(engine.bars, 8),
                takeStart: engine.takeStart, takeDone: engine.takeDone)

      HStack(spacing: 12) {
        Spacer()
        roundBtn(system: "stop.fill", size: 56) { engine.stop() }
        Button(action: { engine.record() }) {
          Circle()
            .fill(engine.recording ? LS.record : LS.surface2)
            .frame(width: 72, height: 72)
            .overlay(
              // How much of the loop the take has so far; it closes when the ring does.
              Circle()
                .trim(from: 0, to: engine.takeDone)
                .stroke(LS.recordFg, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(4)
            )
            .overlay(
              Circle()
                .fill(engine.recording ? LS.recordFg : LS.record)
                .frame(width: 22, height: 22)
            )
        }
        .accessibilityLabel("Record")
        roundBtn(system: engine.running ? "pause.fill" : "play.fill", size: 56, filled: true) { engine.play() }
        Button {
          if engine.sessionRecording { engine.stopSessionRecord() } else { engine.startSessionRecord() }
        } label: {
          Image(systemName: "recordingtape")
            .foregroundStyle(engine.sessionRecording ? LS.record : LS.fg)
            .frame(width: 44, height: 44)
            .background(LS.surface2, in: Circle())
        }
        .accessibilityLabel("Record session")
        Spacer()
      }

      sendToSongRow

      VStack(alignment: .leading, spacing: 8) {
        Text("LENGTH")
          .font(.system(size: 11, weight: .medium))
          .tracking(1.6)
          .foregroundStyle(LS.subtle)
        HStack(spacing: 6) {
          ForEach(engine.barPresets, id: \.self) { n in
            pill(n >= 16 ? "\(n)" : "\(n)", on: engine.bars == n, disabled: engine.loopLocked) {
              engine.setBars(n)
            }
          }
        }
        HStack {
          Slider(value: Binding(
            get: { Double(engine.bpm) },
            set: { engine.setBpm(Int($0)) }
          ), in: 40...220, step: 1)
          .tint(LS.fg)
          Button("Tap") {
            let now = Date().timeIntervalSince1970
            taps = taps.filter { now - $0 < 2.5 } + [now]
            engine.tapTempo(taps)
          }
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(LS.muted)
          .disabled(engine.loopLocked)
        }
        HStack(spacing: 8) {
          toggle("Metronome", engine.metronomeOn) { engine.setMetronomeOn($0) }
          toggle("Count-in", engine.countInOn) { engine.setCountInOn($0) }
          Button("Clear") { engine.clear() }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(LS.muted)
        }
      }
    }
  }

  /// Send to song: captures one full pass of the stack (loops, effects, mutes, solos,
  /// drums) and adds it to the song as a block.
  private var sendToSongRow: some View {
    VStack(spacing: 6) {
      Button { engine.sendToSong() } label: {
        HStack(spacing: 8) {
          Image(systemName: "rectangle.stack.badge.plus")
          Text(engine.sendingToSong ? "Sending one pass… \(Int(engine.sendProgress * 100))%" : "Send to song")
        }
        .font(.system(size: 14, weight: .medium))
        // Still readable when there's nothing to send yet, so it's easy to find.
        .foregroundStyle(engine.canSendToSong ? LS.fg : LS.muted)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
          GeometryReader { g in
            ZStack(alignment: .leading) {
              Capsule().fill(LS.surface2)
              if engine.sendingToSong {
                Capsule().fill(LS.accent.opacity(0.35))
                  .frame(width: g.size.width * CGFloat(engine.sendProgress))
              }
            }
          }
        )
        .clipShape(Capsule())
      }
      .buttonStyle(.plain)
      .disabled(!engine.canSendToSong || engine.sendingToSong)
      if !engine.canSendToSong {
        Text("Record a loop or turn on drums, then send the stack to your song.")
          .font(.system(size: 12))
          .foregroundStyle(LS.subtle)
          .multilineTextAlignment(.center)
      }
      if let note = engine.sendNote {
        Button(action: openSong) {
          Text("\(note) · View song")
            .font(.system(size: 12))
            .foregroundStyle(LS.accent)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var statusText: String {
    switch engine.status {
    case .idle: return "STOPPED"
    case .playing: return "PLAYING"
    case .countin: return "COUNT-IN \(engine.countInBeat + 1)"
    case .recording: return engine.takeStart < 0 ? "RECORDING" : "RECORDING \(Int(engine.takeDone * 100))%"
    }
  }

  private var barLabel: String {
    let beat = Int(engine.position * Double(engine.bars * 4))
    let bar = beat / 4 + 1
    return "Bar \(min(bar, engine.bars))/\(engine.bars)"
  }

}

struct LayersView: View {
  @ObservedObject var engine: LoopEngine
  var body: some View {
    card {
      HStack {
        Text("Layers")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(LS.fg)
        Spacer()
        Text("\(engine.layers.count) overdub\(engine.layers.count == 1 ? "" : "s")")
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(LS.muted)
      }
      if engine.layers.isEmpty {
        Text("Press record anywhere in the loop and play the keys, or open a microphone. It captures one full pass and closes where it started, then the layer lands here.")
          .font(.system(size: 14))
          .foregroundStyle(LS.muted)
      } else {
        ForEach(Array(engine.layers.enumerated()), id: \.element.id) { index, layer in
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(String(format: "%02d", index + 1))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(LS.subtle)
              Text(layer.name)
                .foregroundStyle(LS.fg)
              Spacer()
              HStack(spacing: 2) {
                rowButton("Rev", on: layer.reversed) { engine.toggleReverse(layer.id) }
                rowButton("½", on: layer.halfSpeed, size: 15) { engine.toggleHalfSpeed(layer.id) }
                  .accessibilityLabel(layer.halfSpeed ? "Half speed on" : "Half speed")
                rowButton(layer.muted ? "Muted" : "Mute", on: false) { engine.toggleMute(layer.id) }
                rowButton("Solo", on: layer.soloed) { engine.toggleSolo(layer.id) }
                  .accessibilityLabel(layer.soloed ? "Solo on" : "Solo")
                rowButton("Delete", on: false, color: LS.record) { engine.deleteLayer(layer.id) }
              }
            }
            PeakView(
              // The waveform as recorded; with Rev the playhead runs backwards over it
              // (reversed playback is at the mirrored point), and a half-speed loop's
              // playhead crosses it over two cycles.
              peaks: layer.peaks,
              position: layer.reversed ? 1 - engine.displayPosition(for: layer) : engine.displayPosition(for: layer),
              running: engine.running,
              muted: engine.isSilenced(layer),
              recording: engine.recording && index == engine.layers.count - 1
            )
            FxStrip(
              name: layer.name,
              vol: layer.gain, pan: layer.pan,
              delay: layer.delay, reverb: layer.reverb,
              onVol: { engine.setLayerGain(layer.id, $0) },
              onPan: { engine.setLayerPan(layer.id, $0) },
              onDelay: { engine.setLayerDelay(layer.id, $0) },
              onReverb: { engine.setLayerReverb(layer.id, $0) },
              extra: ("Drive", layer.drive, { engine.setLayerDrive(layer.id, $0) })
            )
          }
          .padding(8)
          .background(LS.bg.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .opacity(layer.muted ? 0.7 : 1)
        }
      }
    }
  }
}

struct InstrumentView: View {
  @ObservedObject var engine: LoopEngine
  @State private var synthOpen = false
  @State private var saveOpen = false
  @State private var saveName = ""

  /// MIDI keyboards: what's connected, and Bluetooth pairing (USB needs no setup).
  private var midiRow: some View {
    HStack(spacing: 8) {
      Text("MIDI")
        .font(.system(size: 11, weight: .medium))
        .tracking(1.4)
        .foregroundStyle(LS.subtle)
      Text(engine.midiDevices.isEmpty ? "Plug in a keyboard, or pair one" : engine.midiDevices.joined(separator: ", "))
        .font(.system(size: 12))
        .foregroundStyle(engine.midiDevices.isEmpty ? LS.muted : LS.fg)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 8)
      Button { BluetoothMIDIPresenter.present() } label: {
        Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(LS.fg)
          .frame(minHeight: 36)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Connect a Bluetooth MIDI keyboard")
    }
  }

  var body: some View {
    card {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("INSTRUMENT")
            .font(.system(size: 11, weight: .medium))
            .tracking(2)
            .foregroundStyle(LS.subtle)
          Text("Sound & pads")
            .font(.system(size: 18, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(LS.fg)
        }
        Spacer()
        HStack(spacing: 6) {
          pill("Keys", on: engine.inputMode == "keys") { engine.setInputMode("keys") }
          pill("Sampler", on: engine.inputMode == "sampler") { engine.setInputMode("sampler") }
          pill("Mic", on: engine.inputMode == "mic") { engine.setInputMode("mic") }
        }
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(InstrumentPreset.allCases) { p in
            pill(p.label, on: engine.preset == p && engine.activeSoundId == nil && engine.inputMode != "sampler" && engine.acousticId == nil) {
              engine.setPreset(p)
            }
          }
          ForEach(engine.savedSounds) { sound in
            HStack(spacing: 0) {
              pill(sound.name, on: engine.activeSoundId == sound.id) { engine.loadSound(sound.id) }
              Button {
                engine.deleteSound(sound.id)
              } label: {
                Image(systemName: "xmark")
                  .font(.system(size: 9, weight: .bold))
                  .foregroundStyle(LS.subtle)
                  .frame(width: 22, height: 36)
              }
              .accessibilityLabel("Delete \(sound.name)")
            }
            .background(LS.surface2, in: Capsule())
          }
        }
      }

      if engine.inputMode == "keys" {
        acousticRow
      }

      // Pads sit right under the sounds, close to the transport above, so recording
      // after a count-in doesn't mean scrolling past the settings. Settings follow.
      if engine.inputMode != "mic" {
        KeyPadView(engine: engine)
        midiRow
      }

      HStack {
        Button("Save sound") {
          saveName = engine.savedSounds.first(where: { $0.id == engine.activeSoundId })?.name ?? ""
          saveOpen = true
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(LS.fg)
        Spacer()
        if engine.inputMode == "sampler" {
          Text(engine.hasSample ? "Pads play the take" : "Capture, then play")
            .font(.system(size: 12))
            .foregroundStyle(LS.muted)
        }
      }

      if engine.inputMode == "sampler" {
        samplerBlock
      }

      if engine.inputMode == "keys" {
        synthDisclosure
      }

      if engine.inputMode == "mic" {
        micBlock
      }
    }
    .alert("Save sound", isPresented: $saveOpen) {
      TextField("Name", text: $saveName)
      Button("Save") { engine.saveCurrentSound(saveName) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(engine.inputMode == "sampler"
           ? "Stores this sample and the current mix."
           : "Stores the current synth settings.")
    }
  }

  /// Sampled acoustic instruments: pianos, strings, winds, mallets.
  private var acousticRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        Text("ACOUSTIC")
          .font(.system(size: 11, weight: .medium))
          .tracking(1.4)
          .foregroundStyle(LS.subtle)
          .padding(.trailing, 2)
        ForEach(AcousticInstrument.catalog, id: \.id) { item in
          pill(engine.acousticLoading == item.id ? "\(item.name)…" : item.name,
               on: engine.acousticId == item.id || engine.acousticLoading == item.id) {
            engine.setAcoustic(item.id)
          }
        }
      }
    }
  }

  private var synthDisclosure: some View {
    VStack(alignment: .leading, spacing: 12) {
      #if DEBUG
      Color.clear.frame(height: 0).id("synthpanel")
        .onAppear { if engine.demoScene == "synth" { synthOpen = true } }
      #endif
      Button {
        withAnimation(.easeInOut(duration: 0.18)) { synthOpen.toggle() }
      } label: {
        HStack(spacing: 10) {
          Text("SYNTH")
            .font(.system(size: 11, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(LS.subtle)
          Text(synthOpen ? "Hide sliders" : (engine.acousticId == nil ? "Osc, filter, space" : "Space and tape"))
            .font(.system(size: 13))
            .foregroundStyle(LS.muted)
          Spacer()
          Image(systemName: "chevron.down")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(LS.muted)
            .rotationEffect(.degrees(synthOpen ? 180 : 0))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(synthOpen ? "Hide synth controls" : "Show synth controls")

      if synthOpen {
        // Acoustic instruments keep level, space and tape; the synth's own controls hide.
        if engine.acousticId == nil {
        Text("OSC 1")
          .font(.system(size: 11, weight: .medium))
          .tracking(1.4)
          .foregroundStyle(LS.subtle)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(OscWave.allCases) { w in
              pill(w.label, on: engine.instrumentWave == w) { engine.setInstrumentWave(w) }
            }
          }
        }
        Text("OSC 2")
          .font(.system(size: 11, weight: .medium))
          .tracking(1.4)
          .foregroundStyle(LS.subtle)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(OscWave.allCases) { w in
              pill(w.label, on: engine.instrumentWave2 == w) { engine.setInstrumentWave2(w) }
            }
          }
        }
        HStack(spacing: 6) {
          Text("OCT")
            .font(.system(size: 11, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(LS.subtle)
          pill("-12", on: engine.osc2Octave == -1) { engine.setOsc2Octave(-1) }
          pill("0", on: engine.osc2Octave == 0) { engine.setOsc2Octave(0) }
          pill("+12", on: engine.osc2Octave == 1) { engine.setOsc2Octave(1) }
        }
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
          FxRow(label: "Mix", value: engine.oscMix, display: "\(Int(engine.oscMix * 100))", onChange: engine.setOscMix)
          FxRow(label: "Det", value: engine.oscDetune, display: "\(Int(engine.oscDetune * 24))c", onChange: engine.setOscDetune)
          FxRow(label: "Cut", value: engine.cutoff, display: "\(Int(engine.cutoff * 100))", onChange: engine.setCutoff)
          FxRow(label: "Q", value: engine.resonance, display: "\(Int(engine.resonance * 100))", onChange: engine.setResonance)
        }
        if engine.instrumentWave == .fm || engine.instrumentWave2 == .fm {
          FxRow(label: "FM", value: engine.instrumentFM, display: "\(Int(engine.instrumentFM * 100))", onChange: engine.setInstrumentFM)
        }
        }
        if engine.acousticId == nil {
          FxStrip(
            name: "Keys",
            vol: engine.instrumentGain, pan: engine.instrumentPan,
            delay: engine.instrumentDelay, reverb: engine.instrumentReverb,
            onVol: engine.setInstrumentGain, onPan: engine.setInstrumentPan,
            onDelay: engine.setInstrumentDelay, onReverb: engine.setInstrumentReverb,
            extra: ("Drift", engine.instrumentDrift, engine.setInstrumentDrift),
            extra2: ("Glitch", engine.instrumentGlitch, engine.setInstrumentGlitch)
          )
        } else {
          // Drift and Glitch act on the synth only.
          FxStrip(
            name: "Keys",
            vol: engine.instrumentGain, pan: engine.instrumentPan,
            delay: engine.instrumentDelay, reverb: engine.instrumentReverb,
            onVol: engine.setInstrumentGain, onPan: engine.setInstrumentPan,
            onDelay: engine.setInstrumentDelay, onReverb: engine.setInstrumentReverb
          )
        }
        FxRow(label: "Tune", value: Float((engine.instrumentTune - 428) / 24), display: "\(Int(engine.instrumentTune))hz") { v in
          engine.setInstrumentTune(428 + Double(v) * 24)
        }
        if engine.acousticId == nil {
        FxRow(label: "Ring", value: engine.instrumentRing, display: "\(Int(engine.instrumentRing * 100))", onChange: engine.setInstrumentRing)
        FxRow(label: "Rel", value: engine.instrumentRelease, display: releaseLabel(engine.instrumentRelease), onChange: engine.setInstrumentRelease)
        }
        FxRow(label: "Tape", value: engine.instrumentTape, display: "\(Int(engine.instrumentTape * 100))", onChange: engine.setInstrumentTape)
        FxRow(label: "Wear", value: engine.instrumentWear, display: "\(Int(engine.instrumentWear * 100))", onChange: engine.setInstrumentWear)
      }
    }
  }

  private var samplerBlock: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Speak, play, or plug in a source. Capture writes a sample. Pads play it in the selected key, and loop record captures those hits.")
        .font(.system(size: 14))
        .foregroundStyle(LS.muted)
      if engine.micState == .denied || engine.micState == .error {
        Text(engine.micError ?? "Microphone is unavailable.")
          .font(.system(size: 14))
          .foregroundStyle(LS.muted)
        Button("Try again") { engine.enableMic() }
          .foregroundStyle(LS.fg)
      }
      Button {
        engine.toggleSampleRecord()
      } label: {
        Text(engine.sampleRecording ? "Stop capture" : (engine.hasSample ? "Recapture" : "Capture sample"))
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(engine.sampleRecording ? LS.recordFg : LS.bg)
          .frame(height: 44)
          .frame(maxWidth: .infinity)
          .background(engine.sampleRecording ? LS.record : LS.fg, in: Capsule())
      }
      if let err = engine.saveError {
        Text(err)
          .font(.system(size: 13))
          .foregroundStyle(LS.record)
      }
      FxStrip(
        name: "Sample",
        vol: engine.instrumentGain, pan: engine.instrumentPan,
        delay: engine.instrumentDelay, reverb: engine.instrumentReverb,
        onVol: engine.setInstrumentGain, onPan: engine.setInstrumentPan,
        onDelay: engine.setInstrumentDelay, onReverb: engine.setInstrumentReverb
      )
    }
  }

  private var micBlock: some View {
    VStack(alignment: .leading, spacing: 10) {
      if engine.micState == .ready {
        Text("Live input into the loop. Use Sampler if you want to play a take from the pads.")
          .font(.system(size: 14))
          .foregroundStyle(LS.muted)
      } else if engine.micState == .denied || engine.micState == .error {
        Text(engine.micError ?? "Microphone is unavailable. Use the keys instead.")
          .font(.system(size: 14))
          .foregroundStyle(LS.muted)
        Button("Try again") { engine.enableMic() }
          .foregroundStyle(LS.fg)
      } else if engine.micState == .pending {
        Text("Requesting microphone access…")
          .font(.system(size: 14))
          .foregroundStyle(LS.muted)
      } else {
        Button("Enable microphone") { engine.enableMic() }
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(LS.bg)
          .frame(height: 44)
          .padding(.horizontal, 16)
          .background(LS.fg, in: Capsule())
      }
      Toggle("Monitor", isOn: Binding(get: { engine.monitorOn }, set: { engine.setMonitorOn($0) }))
        .tint(LS.accent)
        .foregroundStyle(LS.fg)
      if engine.monitorOn && !engine.headphonesOn {
        Text("Plug in headphones to hear yourself. On the speaker the mic would feed back.")
          .font(.system(size: 12))
          .foregroundStyle(LS.subtle)
      }
    }
  }
}

struct KeyPadView: View {
  @ObservedObject var engine: LoopEngine
  @Environment(\.horizontalSizeClass) private var sizeClass

  private var columns: Int { engine.scaleMode == .chromatic ? 6 : 4 }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Pads first, right under the sound choices, so they're a short reach from
      // Record; key, scale and arp settings follow.
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
        spacing: 8
      ) {
        ForEach(engine.padNotes) { note in
          let on = engine.heldNotes.contains(note.midi) || engine.latchedPads.contains(note.midi) || engine.midiHeld.contains(note.midi)
          Text(engine.padLabel(note))
            .font(.system(size: 16, weight: note.isRoot ? .semibold : .medium, design: .monospaced))
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .foregroundStyle(on ? LS.bg : (note.isRoot ? LS.fg : LS.muted))
            .frame(maxWidth: .infinity)
            // Bigger pads on iPad, where there's room to play them with fingers spread.
            .frame(height: sizeClass == .regular
                   ? (engine.scaleMode == .chromatic ? 72 : 96)
                   : (engine.scaleMode == .chromatic ? 52 : 64))
            .background(
              on ? LS.accent : (note.isRoot ? LS.surface2 : LS.bg),
              in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(Rectangle())
            .modifier(PadTouch(midi: note.midi, engine: engine))
            .accessibilityLabel(note.label)
        }
      }
      HStack {
        Text("KEY")
          .font(.system(size: 11, weight: .medium))
          .tracking(1.6)
          .foregroundStyle(LS.subtle)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 4) {
            ForEach(0..<12, id: \.self) { pc in
              let label = MusicKey.name(pc: pc, flats: MusicKey.usesFlats(root: engine.scaleRoot, mode: engine.scaleMode))
              pill(label, on: engine.scaleRoot == pc) { engine.setScaleRoot(pc) }
            }
          }
        }
      }
      HStack(spacing: 6) {
        ForEach(ScaleMode.allCases) { mode in
          pill(mode.label, on: engine.scaleMode == mode) { engine.setScaleMode(mode) }
        }
        Spacer()
        Button { engine.setInstrumentOctave(engine.instrumentOctave - 1) } label: {
          Image(systemName: "minus").frame(width: 32, height: 32)
        }
        .foregroundStyle(LS.fg)
        .disabled(engine.instrumentOctave <= -3)
        Text(engine.instrumentOctave > 0 ? "+\(engine.instrumentOctave)" : "\(engine.instrumentOctave)")
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(LS.muted)
          .frame(width: 16)
        Button { engine.setInstrumentOctave(engine.instrumentOctave + 1) } label: {
          Image(systemName: "plus").frame(width: 32, height: 32)
        }
        .foregroundStyle(LS.fg)
        .disabled(engine.instrumentOctave >= 3)
      }
      HStack(spacing: 6) {
        pill("Arp", on: engine.arpOn) { engine.setArpOn(!engine.arpOn) }
        pill("Chord", on: engine.chordMode) { engine.setChordMode(!engine.chordMode) }
        if engine.chordMode {
          pill("Triad", on: !engine.chordSevenths) { engine.setChordSevenths(false) }
          pill("7th", on: engine.chordSevenths) { engine.setChordSevenths(true) }
        }
      }
      if engine.arpOn {
        HStack(spacing: 6) {
          pill("1/4", on: engine.arpDivision == 1) { engine.setArpDivision(1) }
          pill("1/8", on: engine.arpDivision == 2) { engine.setArpDivision(2) }
          pill("1/16", on: engine.arpDivision == 4) { engine.setArpDivision(4) }
          pill("1/32", on: engine.arpDivision == 8) { engine.setArpDivision(8) }
        }
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            pill("Up", on: engine.arpMode == 0) { engine.setArpMode(0) }
            pill("Down", on: engine.arpMode == 1) { engine.setArpMode(1) }
            pill("Ping", on: engine.arpMode == 2) { engine.setArpMode(2) }
            pill("Order", on: engine.arpMode == 3) { engine.setArpMode(3) }
            pill("Rand", on: engine.arpMode == 4) { engine.setArpMode(4) }
          }
        }
        HStack(spacing: 6) {
          Text("OCT")
            .font(.system(size: 11, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(LS.subtle)
          ForEach(1...4, id: \.self) { n in
            pill("\(n)", on: engine.arpOctaves == n) { engine.setArpOctaves(n) }
          }
          Spacer(minLength: 0)
          pill("Latch", on: engine.arpLatch) { engine.setArpLatch(!engine.arpLatch) }
        }
        if engine.arpLatch {
          Text(engine.latchedPads.isEmpty
               ? "Tap pads to build the pattern. Tap one again to take it out."
               : "\(engine.latchedPads.count) pad\(engine.latchedPads.count == 1 ? "" : "s") in the pattern. Tap a lit pad to take it out.")
            .font(.system(size: 12))
            .foregroundStyle(LS.muted)
        }
      }
    }
  }
}

/// A pad's touch. Presses the moment a finger lands, releases when it lifts, and also
/// releases when iOS cancels the touch (say the page starts scrolling under a finger
/// that moved slightly), which used to leave the note stuck on.
private struct PadTouch: ViewModifier {
  let midi: Int
  let engine: LoopEngine
  @GestureState private var touching = false

  func body(content: Content) -> some View {
    content
      .gesture(
        DragGesture(minimumDistance: 0)
          .updating($touching) { _, state, _ in state = true }
          .onChanged { _ in engine.pressNote(midi) }
          .onEnded { _ in engine.releaseNote(midi) }
      )
      // Gesture state resets on end *and* on cancel; releasing twice is harmless.
      .onChange(of: touching) { down in
        if !down { engine.releaseNote(midi) }
      }
  }
}

struct HardwareTypingView: UIViewRepresentable {
  var onDown: (String) -> Void
  var onUp: (String) -> Void

  func makeUIView(context: Context) -> KeyCatcherView {
    let view = KeyCatcherView()
    view.onDown = onDown
    view.onUp = onUp
    return view
  }

  func updateUIView(_ uiView: KeyCatcherView, context: Context) {
    uiView.onDown = onDown
    uiView.onUp = onUp
  }
}

final class KeyCatcherView: UIView {
  var onDown: ((String) -> Void)?
  var onUp: ((String) -> Void)?

  override var canBecomeFirstResponder: Bool { true }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) { nil }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      DispatchQueue.main.async { _ = self.becomeFirstResponder() }
    }
  }

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    let flags = event?.modifierFlags ?? []
    if flags.contains(.command) || flags.contains(.control) || flags.contains(.alternate) {
      super.pressesBegan(presses, with: event)
      return
    }
    var handled = false
    for press in presses {
      guard let chars = press.key?.charactersIgnoringModifiers, !chars.isEmpty else { continue }
      onDown?(chars)
      handled = true
    }
    if !handled { super.pressesBegan(presses, with: event) }
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    var handled = false
    for press in presses {
      guard let chars = press.key?.charactersIgnoringModifiers, !chars.isEmpty else { continue }
      onUp?(chars)
      handled = true
    }
    if !handled { super.pressesEnded(presses, with: event) }
  }

  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    pressesEnded(presses, with: event)
  }
}

struct DrumsView: View {
  @ObservedObject var engine: LoopEngine
  var body: some View {
    card {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("DRUMS")
            .font(.system(size: 11, weight: .medium))
            .tracking(2)
            .foregroundStyle(LS.subtle)
          Text(engine.drumName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(LS.fg)
        }
        Spacer()
        pill("Jam", on: engine.jamMode) { engine.setJam(!engine.jamMode) }
        pill("Fill", on: engine.fillArmed) { engine.requestFill() }
        Toggle("", isOn: Binding(get: { engine.drumsOn }, set: { engine.setDrumsOn($0) }))
          .labelsHidden()
          .tint(LS.accent)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(DrumKit.allCases) { kit in
            pill(kit.label, on: engine.drumKit == kit) { engine.setDrumKit(kit) }
          }
        }
      }
      Text(
        engine.jamMode
          ? "Varies the groove every bar, plays a half-bar fill every 8 bars, and moves to a related groove every 16."
          : "Starts on the loop downbeat. Fill plays a 1-bar break on the next bar."
      )
        .font(.system(size: 13))
        .foregroundStyle(LS.muted)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(engine.drums) { p in
            pill(p.name, on: engine.drumId == p.id) { engine.setDrumId(p.id) }
          }
        }
      }
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        FxRow(label: "Comp", value: engine.drumComp, display: "\(Int(engine.drumComp * 100))", onChange: engine.setDrumComp)
        FxRow(label: "Drive", value: engine.drumDrive, display: "\(Int(engine.drumDrive * 100))", onChange: engine.setDrumDrive)
        FxRow(label: "Dirt", value: engine.drumDirt, display: "\(Int(engine.drumDirt * 100))", onChange: engine.setDrumDirt)
        FxRow(label: "Vinyl", value: engine.drumVinyl, display: "\(Int(engine.drumVinyl * 100))", onChange: engine.setDrumVinyl)
        FxRow(label: "Room", value: engine.drumRoom, display: "\(Int(engine.drumRoom * 100))", onChange: engine.setDrumRoom)
        FxRow(label: "Tape", value: engine.drumTape, display: "\(Int(engine.drumTape * 100))", onChange: engine.setDrumTape)
        FxRow(label: "Wear", value: engine.drumWear, display: "\(Int(engine.drumWear * 100))", onChange: engine.setDrumWear)
        FxRow(label: "Pitch", value: Float(engine.drumPitch + 12) / 24,
              display: engine.drumPitch == 0 ? "0" : String(format: "%+d", engine.drumPitch)) { v in
          engine.setDrumPitch(Int((v * 24).rounded()) - 12)
        }
      }
    }
  }
}

struct MixView: View {
  @ObservedObject var engine: LoopEngine
  var body: some View {
    card {
      HStack {
        Text("Mix")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(LS.fg)
        Spacer()
        LimiterLight(reduction: engine.limiterReduction)
      }
      mix("Master", engine.masterGain) { engine.setMasterGain($0) }
      mix("Keys", engine.instrumentGain) { engine.setInstrumentGain($0) }
      mix("Loops", engine.loopsGain) { engine.setLoopsGain($0) }
      mix("Drums", engine.drumsGain) { engine.setDrumsGain($0) }
      mix("Metronome", engine.metroGain) { engine.setMetroGain($0) }
    }
  }

  private func mix(_ label: String, _ value: Float, _ set: @escaping (Float) -> Void) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(label.uppercased())
          .font(.system(size: 11, weight: .medium))
          .tracking(1.4)
          .foregroundStyle(LS.subtle)
        Spacer()
        Text("\(Int(value * 100))")
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(LS.muted)
      }
      Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }), in: 0...1)
        .tint(LS.fg)
    }
  }
}

struct SessionView: View {
  @ObservedObject var engine: LoopEngine
  var share: (URL) -> Void
  var body: some View {
    card {
      Text("SESSION")
        .font(.system(size: 11, weight: .medium))
        .tracking(2)
        .foregroundStyle(LS.subtle)
      Text("Record & share")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(LS.fg)
      Text("Bounces everything you hear right now — loops, drums, and live playing — into one file you can save or share.")
        .font(.system(size: 14))
        .foregroundStyle(LS.muted)
      HStack {
        if engine.sessionRecording {
          Button {
            engine.stopSessionRecord()
          } label: {
            Label("Stop", systemImage: "stop.fill")
              .foregroundStyle(LS.bg)
              .padding(.horizontal, 16)
              .frame(height: 44)
              .background(LS.fg, in: Capsule())
          }
        } else {
          Button {
            engine.startSessionRecord()
          } label: {
            Label("Record session", systemImage: "circle.fill")
              .foregroundStyle(LS.recordFg)
              .padding(.horizontal, 16)
              .frame(height: 44)
              .background(LS.record, in: Capsule())
          }
        }
        if engine.sessionReady {
          Button("Discard") { engine.clearSession() }
            .foregroundStyle(LS.muted)
        }
      }
      if engine.sessionReady, let url = engine.sessionURL {
        Button {
          share(url)
        } label: {
          Label(String(format: "Save or share (%.0fs)", engine.sessionDuration), systemImage: "square.and.arrow.up")
            .foregroundStyle(LS.fg)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(LS.surface2, in: Capsule())
        }
      }
    }
  }
}

struct PrivacyView: View {
  @State private var open = false
  var body: some View {
    VStack(spacing: 12) {
      Button("Privacy") { open.toggle() }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(LS.subtle)
        .frame(maxWidth: .infinity)
      if open {
        VStack(alignment: .leading, spacing: 10) {
          Text("Loopstack is a local instrument. Microphone audio is processed on this device so you can record loop layers. Nothing is uploaded, and there is no account.")
          Text("A recording only leaves the device if you tap Save or Share and pick a destination in the system sheet (Files, Mail, and so on).")
          Text("The app does not show ads, does not track you, and does not sell data.")
        }
        .font(.system(size: 14))
        .foregroundStyle(LS.muted)
        .padding(16)
        .background(LS.surface, in: RoundedRectangle(cornerRadius: 16))
      }
    }
  }
}

/// The song: blocks sent from the stack, played in order. Each block plays its captured
/// pass `repeats` times.
struct SongView: View {
  @ObservedObject var engine: LoopEngine
  var backToStack: () -> Void

  var body: some View {
    card {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("SONG")
            .font(.system(size: 11, weight: .medium))
            .tracking(2)
            .foregroundStyle(LS.subtle)
          Text(engine.songBlocks.isEmpty ? "No blocks yet" : "\(engine.songBlocks.count) block\(engine.songBlocks.count == 1 ? "" : "s") · \(time(engine.songLength))")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(LS.fg)
        }
        Spacer()
        Button { engine.toggleSong() } label: {
          Image(systemName: engine.songPlaying ? "stop.fill" : "play.fill")
            .foregroundStyle(LS.bg)
            .frame(width: 52, height: 52)
            .background(LS.fg, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(engine.songBlocks.isEmpty)
        .opacity(engine.songBlocks.isEmpty ? 0.4 : 1)
        .accessibilityLabel(engine.songPlaying ? "Stop song" : "Play song")
      }
      if engine.songBlocks.isEmpty {
        Text("Build a loopstack, then press Send to song under the transport. Each send adds one full pass of the stack, exactly as it sounds, as a block here.")
          .font(.system(size: 14))
          .foregroundStyle(LS.muted)
      } else {
        timeline
        if engine.songPlaying {
          Text("\(time(engine.songPosition)) / \(time(engine.songLength))")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(LS.muted)
        }
        VStack(spacing: 0) {
          ForEach(Array(engine.songBlocks.enumerated()), id: \.element.id) { index, block in
            blockRow(block, index: index)
            if index < engine.songBlocks.count - 1 { Divider().overlay(LS.surface2) }
          }
        }
      }
      HStack {
        Button(action: backToStack) {
          Label("Back to stack", systemImage: "chevron.left")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(LS.fg)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        Spacer()
        Button {
          if let url = engine.exportSong() { SharePresenter.present(url) }
        } label: {
          Label("Export song", systemImage: "square.and.arrow.up")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(engine.songBlocks.isEmpty ? LS.subtle : LS.fg)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(engine.songBlocks.isEmpty)
      }
    }
  }

  /// Blocks side by side, sized by how long they play, with the playhead.
  private var timeline: some View {
    GeometryReader { geo in
      let total = max(engine.songLength, 0.001)
      let gap: CGFloat = 3
      let usable = geo.size.width - gap * CGFloat(max(0, engine.songBlocks.count - 1))
      ZStack(alignment: .leading) {
        HStack(spacing: gap) {
          ForEach(engine.songBlocks) { b in
            let w = usable * CGFloat(b.seconds * Double(b.repeats) / total)
            RoundedRectangle(cornerRadius: 4)
              .fill(isCurrent(b) ? LS.accent.opacity(0.8) : LS.surface2)
              .overlay(
                Text(b.repeats > 1 ? "\(short(b))×\(b.repeats)" : short(b))
                  .font(.system(size: 10, weight: .medium, design: .monospaced))
                  .foregroundStyle(isCurrent(b) ? LS.bg : LS.muted)
                  .lineLimit(1)
                  .minimumScaleFactor(0.5)
                  .padding(.horizontal, 2)
              )
              .frame(width: max(2, w))
          }
        }
        if engine.songPlaying {
          Rectangle()
            .fill(LS.fg)
            .frame(width: 2)
            .offset(x: geo.size.width * CGFloat(engine.songPosition / total) - 1)
        }
      }
    }
    .frame(height: 36)
  }

  private func blockRow(_ b: SongBlock, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(b.name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isCurrent(b) ? LS.accent : LS.fg)
          Text("\(b.bars) bar\(b.bars == 1 ? "" : "s") · \(b.bpm) bpm · \(b.detail)")
            .font(.system(size: 12))
            .foregroundStyle(LS.muted)
            .lineLimit(1)
        }
        Spacer()
        HStack(spacing: 0) {
          songButton("minus") { engine.setRepeats(b.id, b.repeats - 1) }
          Text("×\(b.repeats)")
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundStyle(LS.fg)
            .frame(minWidth: 34)
          songButton("plus") { engine.setRepeats(b.id, b.repeats + 1) }
        }
      }
      HStack(spacing: 0) {
        songButton("arrow.up", disabled: index == 0) { engine.moveBlock(b.id, by: -1) }
        songButton("arrow.down", disabled: index == engine.songBlocks.count - 1) { engine.moveBlock(b.id, by: 1) }
        songButton("plus.square.on.square") { engine.duplicateBlock(b.id) }
        Spacer()
        songButton("trash", color: LS.record) { engine.deleteBlock(b.id) }
      }
    }
    .padding(.vertical, 8)
  }

  private func songButton(_ icon: String, disabled: Bool = false, color: Color? = nil, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(disabled ? LS.subtle.opacity(0.4) : (color ?? LS.muted))
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
  }

  /// The block under the playhead.
  private func isCurrent(_ b: SongBlock) -> Bool {
    guard engine.songPlaying else { return false }
    var t = 0.0
    for x in engine.songBlocks {
      let len = x.seconds * Double(x.repeats)
      if engine.songPosition < t + len { return x.id == b.id }
      t += len
    }
    return false
  }

  private func short(_ b: SongBlock) -> String { b.name.replacingOccurrences(of: "Block ", with: "") }

  private func time(_ s: Double) -> String {
    let t = Int(s.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
  }
}

struct LoopRuler: View {
  var position: Double
  var recording: Bool
  var running: Bool
  var bars: Int
  /// The take in progress, as loop fractions: where it began (-1: none) and how much it has.
  var takeStart: Double = -1
  var takeDone: Double = 0
  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(LS.surface2)
        if takeStart >= 0 {
          // Captured so far, from where record was pressed, wrapping round the loop.
          let w = geo.size.width
          let first = min(takeDone, 1 - takeStart)
          Rectangle()
            .fill(LS.record.opacity(0.45))
            .frame(width: CGFloat(first) * w)
            .offset(x: CGFloat(takeStart) * w)
          Rectangle()
            .fill(LS.record.opacity(0.45))
            .frame(width: CGFloat(max(0, takeDone - first)) * w)
        }
        Capsule()
          .fill(recording ? LS.record : LS.accent)
          .frame(width: 3)
          .offset(x: max(0, CGFloat(position) * geo.size.width - 1.5))
          .opacity(running || recording ? 1 : 0.3)
      }
      .clipShape(Capsule())
    }
    .frame(height: 8)
  }
}

/// Loop-row button with a full-size touch target (44 pt tall, at least 40 wide).
private func rowButton(_ title: String, on: Bool, size: CGFloat = 12, color: Color? = nil, action: @escaping () -> Void) -> some View {
  Button(action: action) {
    Text(title)
      .font(.system(size: size, weight: size > 12 ? .medium : .regular))
      .foregroundStyle(color ?? (on ? LS.accent : LS.muted))
      .frame(minWidth: 40, minHeight: 44)
      .contentShape(Rectangle())
  }
  .buttonStyle(.plain)
}

struct PeakView: View {
  var peaks: [Float]
  var position: Double
  var running: Bool = false
  var muted: Bool = false
  var recording: Bool = false
  var body: some View {
    Canvas { ctx, size in
      let n = max(peaks.count, 1)
      let w = size.width / CGFloat(n)
      let color = recording ? LS.record : (muted ? LS.subtle : LS.accent)
      for i in 0..<n {
        let p = i < peaks.count ? peaks[i] : 0
        let h = max(2, CGFloat(p) * size.height)
        let rect = CGRect(
          x: CGFloat(i) * w,
          y: (size.height - h) / 2,
          width: max(w * 0.78, 0.8),
          height: h
        )
        ctx.fill(
          Path(roundedRect: rect, cornerRadius: 1),
          with: .color(color.opacity(muted ? 0.35 : 0.45 + Double(p) * 0.55))
        )
      }
      if running {
        let x = max(0, min(size.width - 2, CGFloat(position) * size.width))
        ctx.fill(Path(CGRect(x: x, y: 0, width: 2, height: size.height)), with: .color(LS.record))
      }
    }
    .frame(height: 48)
  }
}

/// Lights when the master limiter is pulling the mix down: accent for light
/// limiting, red past 3 dB (squashing punch; pull the master or loops down).
private struct LimiterLight: View {
  var reduction: Float

  private var color: Color {
    if reduction >= 3 { return LS.record }
    if reduction >= 0.3 { return LS.accent }
    return LS.subtle.opacity(0.5)
  }

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
      Text(reduction >= 0.3 ? String(format: "LIMIT -%.1f dB", reduction) : "LIMIT")
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .tracking(1.2)
        .foregroundStyle(reduction >= 0.3 ? color : LS.subtle)
    }
    .animation(.easeOut(duration: 0.15), value: reduction >= 3)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(reduction >= 0.3 ? String(format: "Limiter reducing %.1f decibels", reduction) : "Limiter idle")
  }
}

private func releaseLabel(_ v: Float) -> String {
  let sec = InstrumentPatch.releaseSeconds(v)
  return sec < 1 ? "\(Int((sec * 1000).rounded()))ms" : String(format: "%.1fs", sec)
}

private struct FxStrip: View {
  var name: String
  var vol, pan, delay, reverb: Float
  var onVol, onPan, onDelay, onReverb: (Float) -> Void
  var extra: (String, Float, (Float) -> Void)?
  var extra2: (String, Float, (Float) -> Void)?

  var body: some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
      FxRow(label: "Vol", value: vol, display: "\(Int(vol * 100))", onChange: onVol)
      FxRow(label: "Pan", value: (pan + 1) / 2, display: panLabel(pan)) { onPan($0 * 2 - 1) }
      FxRow(label: "Dly", value: delay, display: "\(Int(delay * 100))", onChange: onDelay)
      FxRow(label: "Rev", value: reverb, display: "\(Int(reverb * 100))", onChange: onReverb)
      if let extra {
        FxRow(label: extra.0, value: extra.1, display: "\(Int(extra.1 * 100))", onChange: extra.2)
      }
      if let extra2 {
        FxRow(label: extra2.0, value: extra2.1, display: "\(Int(extra2.1 * 100))", onChange: extra2.2)
      }
    }
  }

  private func panLabel(_ pan: Float) -> String {
    if abs(pan) < 0.04 { return "C" }
    return pan < 0 ? "L\(Int(-pan * 100))" : "R\(Int(pan * 100))"
  }
}

private struct FxRow: View {
  var label: String
  var value: Float
  var display: String
  var onChange: (Float) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(label.uppercased())
          .font(.system(size: 11, weight: .medium))
          .tracking(1.2)
          .foregroundStyle(LS.subtle)
        Spacer()
        Text(display)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(LS.muted)
      }
      Slider(value: Binding(get: { Double(value) }, set: { onChange(Float($0)) }), in: 0...1)
        .tint(LS.fg)
    }
  }
}

private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
  VStack(alignment: .leading, spacing: 14) { content() }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(LS.surface, in: RoundedRectangle(cornerRadius: LS.radius, style: .continuous))
}

private func pill(_ title: String, on: Bool, disabled: Bool = false, action: @escaping () -> Void) -> some View {
  Button(action: action) {
    Text(title)
      .font(.system(size: 13, weight: .medium))
      .lineLimit(1)
      .fixedSize()  // a pill never wraps ("Sampler" broke onto two lines on 6.9" phones)
      .foregroundStyle(on ? LS.bg : LS.muted)
      .padding(.horizontal, 12)
      .frame(height: 36)
      .background(on ? LS.fg : LS.surface2, in: Capsule())
  }
  .disabled(disabled)
  .opacity(disabled ? 0.4 : 1)
}

private func toggle(_ title: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
  Button(title) { set(!on) }
    .font(.system(size: 13, weight: .medium))
    .foregroundStyle(on ? LS.bg : LS.muted)
    .padding(.horizontal, 12)
    .frame(height: 36)
    .background(on ? LS.fg : LS.surface2, in: Capsule())
}

private func roundBtn(system: String, size: CGFloat, filled: Bool = false, action: @escaping () -> Void) -> some View {
  Button(action: action) {
    Image(systemName: system)
      .foregroundStyle(filled ? LS.bg : LS.fg)
      .frame(width: size, height: size)
      .background(filled ? LS.fg : LS.surface2, in: Circle())
  }
}

/// Presents the system share sheet from UIKit. On iPad it must be a popover with a
/// source, so it opens centred with no arrow; on iPhone it's the usual sheet.
/// Apple's Bluetooth MIDI pairing screen, in a sheet with a Done button.
enum BluetoothMIDIPresenter {
  @MainActor static func present() {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
          let root = (scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first)?.rootViewController
    else { return }
    var top = root
    while let next = top.presentedViewController { top = next }
    let central = CABTMIDICentralViewController()
    let nav = UINavigationController(rootViewController: central)
    central.navigationItem.rightBarButtonItem = UIBarButtonItem(
      systemItem: .done, primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
    nav.modalPresentationStyle = .formSheet
    top.present(nav, animated: true)
  }
}

enum SharePresenter {
  @MainActor static func present(_ url: URL) {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
          let root = (scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first)?.rootViewController
    else { return }
    var top = root
    while let next = top.presentedViewController { top = next }
    let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    if let pop = sheet.popoverPresentationController {
      pop.sourceView = top.view
      pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
      pop.permittedArrowDirections = []
    }
    top.present(sheet, animated: true)
  }
}
