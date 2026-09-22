import SwiftUI
import UIKit

struct StudioView: View {
  @StateObject private var engine = LoopEngine()
  @State private var shareURL: URL?

  var body: some View {
    ZStack {
      LS.bg.ignoresSafeArea()
      if engine.unlocked {
        desk
      } else {
        GateView { engine.unlock() }
      }
    }
    .preferredColorScheme(.dark)
    .sheet(item: Binding(
      get: { shareURL.map { IdentifiedURL(url: $0) } },
      set: { shareURL = $0?.url }
    )) { item in
      ShareSheet(url: item.url)
    }
  }

  private var desk: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        TransportView(engine: engine)
        LayersView(engine: engine)
        InstrumentView(engine: engine)
        DrumsView(engine: engine)
        MixView(engine: engine)
        SessionView(engine: engine, share: { shareURL = $0 })
        exportRow
        PrivacyView()
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 40)
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

  private var exportRow: some View {
    Button {
      if let url = engine.exportStems() { shareURL = url }
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
    VStack(spacing: 16) {
      Text("AUDIO ROOM")
        .font(.system(size: 11, weight: .medium))
        .tracking(2.4)
        .foregroundStyle(LS.subtle)
      Text("Loopstack")
        .font(.system(size: 48, weight: .semibold))
        .foregroundStyle(LS.fg)
      Text("A layered looper with a metronome, overdubs you can see and delete, and drum loops that lock to the start of your cycle.")
        .font(.system(size: 16))
        .foregroundStyle(LS.muted)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
      Button(action: onStart) {
        Text("Tap to open")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(LS.bg)
          .frame(height: 48)
          .padding(.horizontal, 32)
          .background(LS.fg, in: Capsule())
      }
      .padding(.top, 16)
    }
    .padding(24)
  }
}

struct TransportView: View {
  @ObservedObject var engine: LoopEngine
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
            pill(p.label, on: engine.preset == p) { engine.setPreset(p) }
          }
        }
      }

      LoopRuler(position: engine.position, recording: engine.recording, running: engine.running, bars: min(engine.bars, 8))

      HStack(spacing: 12) {
        Spacer()
        roundBtn(system: "stop.fill", size: 56) { engine.stop() }
        Button(action: { engine.record() }) {
          Circle()
            .fill(engine.recording ? LS.record : LS.surface2)
            .frame(width: 72, height: 72)
            .overlay(
              Circle()
                .stroke(engine.status == .armed ? LS.record.opacity(0.7) : .clear, lineWidth: 2)
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

  private var statusText: String {
    switch engine.status {
    case .idle: return "STOPPED"
    case .playing: return "PLAYING"
    case .countin: return "COUNT-IN \(engine.countInBeat + 1)"
    case .armed: return "ARMED"
    case .recording: return "RECORDING"
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
        Text("Arm record and play the keys, or open a microphone. When the cycle closes, a layer lands here.")
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
              Button("Rev") { engine.toggleReverse(layer.id) }
                .font(.system(size: 12))
                .foregroundStyle(layer.reversed ? LS.accent : LS.muted)
              Button(layer.muted ? "Muted" : "Mute") { engine.toggleMute(layer.id) }
                .font(.system(size: 12))
                .foregroundStyle(LS.muted)
              Button("Delete") { engine.deleteLayer(layer.id) }
                .font(.system(size: 12))
                .foregroundStyle(LS.record)
            }
            PeakView(
              peaks: layer.peaks,
              position: engine.position,
              running: engine.running,
              muted: layer.muted,
              recording: engine.recording && index == engine.layers.count - 1
            )
            FxStrip(
              name: layer.name,
              vol: layer.gain, pan: layer.pan,
              delay: layer.delay, reverb: layer.reverb,
              onVol: { engine.setLayerGain(layer.id, $0) },
              onPan: { engine.setLayerPan(layer.id, $0) },
              onDelay: { engine.setLayerDelay(layer.id, $0) },
              onReverb: { engine.setLayerReverb(layer.id, $0) }
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
  @State private var held: Set<Int> = []

  private let notes: [(midi: Int, label: String, black: Bool)] = {
    let labels = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let black = [false, true, false, true, false, false, true, false, true, false, true, false]
    return (48...72).map { midi in
      let i = midi % 12
      return (midi, labels[i], black[i])
    }
  }()

  var body: some View {
    card {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("INPUT")
            .font(.system(size: 11, weight: .medium))
            .tracking(2)
            .foregroundStyle(LS.subtle)
          Text("Play into the loop")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(LS.fg)
        }
        Spacer()
        HStack(spacing: 6) {
          pill("Keys", on: engine.inputMode == "keys") { engine.setInputMode("keys") }
          pill("Mic", on: engine.inputMode == "mic") { engine.setInputMode("mic") }
        }
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(InstrumentPreset.allCases) { p in
            pill(p.label, on: engine.preset == p) { engine.setPreset(p) }
          }
        }
      }

      if engine.inputMode == "keys" {
        FxStrip(
          name: "Keys",
          vol: engine.instrumentGain, pan: engine.instrumentPan,
          delay: engine.instrumentDelay, reverb: engine.instrumentReverb,
          onVol: engine.setInstrumentGain, onPan: engine.setInstrumentPan,
          onDelay: engine.setInstrumentDelay, onReverb: engine.setInstrumentReverb,
          extra: ("Drift", engine.instrumentDrift, engine.setInstrumentDrift),
          extra2: ("Glitch", engine.instrumentGlitch, engine.setInstrumentGlitch)
        )
        FxRow(label: "Tune", value: Float((engine.instrumentTune - 428) / 24), display: "\(Int(engine.instrumentTune))hz") { v in
          engine.setInstrumentTune(428 + Double(v) * 24)
        }
        FxRow(label: "Ring", value: engine.instrumentRing, display: "\(Int(engine.instrumentRing * 100))") {
          engine.setInstrumentRing($0)
        }
      }

      if engine.inputMode == "mic" {
        if engine.micState == .ready {
          Text("Using iPhone Microphone — Record to capture it into a layer.")
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
      } else {
        HStack {
          Text("OCTAVE")
            .font(.system(size: 11, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(LS.subtle)
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
        noteGrid
      }
    }
  }

  private var noteGrid: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
      ForEach(notes, id: \.midi) { note in
        let midi = note.midi + engine.instrumentOctave * 12
        let on = held.contains(midi)
        Text(note.label)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(on ? LS.bg : (note.black ? LS.subtle : LS.muted))
          .frame(width: 48, height: note.black ? 48 : 64)
          .background(
            on ? LS.accent : (note.black ? LS.surface : LS.bg),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { _ in press(midi) }
              .onEnded { _ in release(midi) }
          )
      }
    }
  }

  private func press(_ n: Int) {
    guard !held.contains(n) else { return }
    held.insert(n)
    engine.noteOn(n)
  }

  private func release(_ n: Int) {
    guard held.contains(n) else { return }
    held.remove(n)
    engine.noteOff(n)
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
        Toggle("", isOn: Binding(get: { engine.drumsOn }, set: { engine.setDrumsOn($0) }))
          .labelsHidden()
          .tint(LS.accent)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(engine.drums) { p in
            pill(p.name, on: engine.drumId == p.id) { engine.setDrumId(p.id) }
          }
        }
      }
    }
  }
}

struct MixView: View {
  @ObservedObject var engine: LoopEngine
  var body: some View {
    card {
      Text("Mix")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(LS.fg)
      mix("Master", engine.masterGain) { engine.setMasterGain($0) }
      mix("Keys", engine.instrumentGain) { engine.setInstrumentGain($0) }
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

struct LoopRuler: View {
  var position: Double
  var recording: Bool
  var running: Bool
  var bars: Int
  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(LS.surface2)
        Capsule()
          .fill(recording ? LS.record : LS.accent)
          .frame(width: 3)
          .offset(x: max(0, CGFloat(position) * geo.size.width - 1.5))
          .opacity(running || recording ? 1 : 0.3)
      }
    }
    .frame(height: 8)
  }
}

struct PeakView: View {
  var peaks: [Float]
  var position: Double
  var running: Bool = false
  var muted: Bool = false
  var recording: Bool = false
  var body: some View {
    GeometryReader { geo in
      let n = max(peaks.count, 1)
      let w = geo.size.width / CGFloat(n)
      let color = recording ? LS.record : (muted ? LS.subtle : LS.accent)
      ZStack(alignment: .leading) {
        HStack(alignment: .center, spacing: 0) {
          ForEach(0..<n, id: \.self) { i in
            Capsule()
              .fill(color.opacity(muted ? 0.35 : 0.45 + Double(peaks[i]) * 0.55))
              .frame(width: max(1, w - 1), height: max(2, CGFloat(peaks[i]) * geo.size.height))
          }
        }
        if running {
          Rectangle()
            .fill(LS.record)
            .frame(width: 2, height: geo.size.height)
            .offset(x: max(0, CGFloat(position) * geo.size.width - 1))
        }
      }
    }
    .frame(height: 48)
  }
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

private struct IdentifiedURL: Identifiable {
  var url: URL
  var id: String { url.absoluteString }
}

private struct ShareSheet: UIViewControllerRepresentable {
  var url: URL
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [url], applicationActivities: nil)
  }
  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
