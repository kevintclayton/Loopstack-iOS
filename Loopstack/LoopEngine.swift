import AVFoundation
import Combine
import Foundation
import UIKit

enum TransportStatus: String {
  case idle, playing, countin, armed, recording
}

enum MicState: String {
  case idle, pending, ready, denied, error
}

final class LayerSlot {
  let player = AVAudioPlayerNode()
  let mixer = AVAudioMixerNode()
  let delay = AVAudioUnitDelay()
  let reverb = AVAudioUnitReverb()
  var busy = false
}

struct InstrumentPatch {
  var gain: Float = 0.85
  var pan: Float = 0
  var delay: Float = 0.92
  var reverb: Float = 0.95
  var drift: Float = 0.66
  var ring: Float = 0.78
  var glitch: Float = 0
  var tune: Double = 437
  var octave: Int = 0
}

struct Layer: Identifiable {
  var id: String
  var name: String
  var buffer: AVAudioPCMBuffer
  var reverseBuffer: AVAudioPCMBuffer
  var peaks: [Float]
  var gain: Float
  var pan: Float
  var delay: Float
  var reverb: Float
  var muted: Bool
  var reversed: Bool
  var slot: LayerSlot
}

@MainActor
final class LoopEngine: ObservableObject {
  @Published var unlocked = false
  @Published var status: TransportStatus = .idle
  @Published var bpm: Int = 96
  @Published var bars: Int = 4
  @Published var metronomeOn = true
  @Published var countInOn = true
  @Published var monitorOn = false
  @Published var drumsOn = false
  @Published var drumId = "floor"
  @Published var masterGain: Float = 0.85
  @Published var metroGain: Float = 0.83
  @Published var drumsGain: Float = 0.83
  @Published var instrumentGain: Float = 0.85
  @Published var instrumentPan: Float = 0
  @Published var instrumentDelay: Float = 0.92
  @Published var instrumentReverb: Float = 0.95
  @Published var instrumentDrift: Float = 0.66
  @Published var instrumentRing: Float = 0.78
  @Published var instrumentGlitch: Float = 0
  @Published var micGain: Float = 0.85
  @Published var layers: [Layer] = []
  @Published var micState: MicState = .idle
  @Published var micError: String?
  @Published var inputMode: String = "keys"
  @Published var preset: InstrumentPreset = .keys
  @Published var audioRunning = false
  @Published var sessionRecording = false
  @Published var sessionReady = false
  @Published var sessionURL: URL?
  @Published var sessionDuration: Double = 0
  @Published var sessionElapsed: Double = 0
  @Published var position: Double = 0
  @Published var countInBeat = 0
  @Published var loopLocked = false
  @Published var instrumentTune: Double = 437
  @Published var instrumentOctave: Int = 0
  @Published var privacyOpen = false
  private var patches: [InstrumentPreset: InstrumentPatch] = {
    var all: [InstrumentPreset: InstrumentPatch] = [:]
    for p in InstrumentPreset.allCases { all[p] = InstrumentPatch() }
    return all
  }()

  let drums = DrumLibrary.all
  let barPresets = [1, 2, 4, 8, 16, 32, 64, 128]

  var drumName: String { DrumLibrary.find(drumId).name }
  var running: Bool { status != .idle }
  var recording: Bool { status == .recording }

  private let engine = AVAudioEngine()
  private var format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
  private let sessionMixer = AVAudioMixerNode()
  private let loopsMixer = AVAudioMixerNode()
  private let drumsMixer = AVAudioMixerNode()
  private let metroMixer = AVAudioMixerNode()
  private let instMixer = AVAudioMixerNode()
  private let instDelay = AVAudioUnitDelay()
  private let instReverb = AVAudioUnitReverb()
  private let micMixer = AVAudioMixerNode()
  private let drumsPlayer = AVAudioPlayerNode()
  private let metroPlayer = AVAudioPlayerNode()
  private var voicePool: [AVAudioPlayerNode] = []
  private var busyVoices: [Int: AVAudioPlayerNode] = [:]
  private var layerSlots: [LayerSlot] = []
  private var cycleStart: TimeInterval = 0
  private var clock: Timer?
  private var capture: [Float] = []
  private var captureTarget = 0
  private var capturing = false
  private var sessionL: [Float] = []
  private var sessionR: [Float] = []
  private var sessionStarted: TimeInterval = 0
  private var layerSerial = 1
  private var tapInstalled = false
  private var sessionTapInstalled = false
  private var micArmed = false

  var loopDuration: Double { Double(bars * 4) * 60 / Double(bpm) }

  func unlock() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
      try session.setActive(true)
      let sr = session.sampleRate > 0 ? session.sampleRate : 44100
      format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
      attachGraph()
      try engine.start()
      unlocked = true
      audioRunning = true
      startClock()
    } catch {
      micError = error.localizedDescription
    }
  }

  private func attachGraph() {
    [sessionMixer, loopsMixer, drumsMixer, metroMixer, instMixer, instDelay, instReverb, micMixer, drumsPlayer, metroPlayer].forEach { engine.attach($0) }
    engine.connect(drumsPlayer, to: drumsMixer, format: format)
    engine.connect(metroPlayer, to: metroMixer, format: format)
    engine.connect(drumsMixer, to: sessionMixer, format: format)
    engine.connect(metroMixer, to: sessionMixer, format: format)
    engine.connect(loopsMixer, to: sessionMixer, format: format)
    engine.connect(instMixer, to: instDelay, format: format)
    engine.connect(instDelay, to: instReverb, format: format)
    engine.connect(instReverb, to: sessionMixer, format: format)
    engine.connect(micMixer, to: sessionMixer, format: format)
    engine.connect(sessionMixer, to: engine.mainMixerNode, format: format)
    instDelay.feedback = 38
    instReverb.loadFactoryPreset(.mediumHall)

    for _ in 0..<12 {
      let player = AVAudioPlayerNode()
      engine.attach(player)
      engine.connect(player, to: instMixer, format: format)
      voicePool.append(player)
    }
    for _ in 0..<8 {
      let slot = LayerSlot()
      engine.attach(slot.player)
      engine.attach(slot.mixer)
      engine.attach(slot.delay)
      engine.attach(slot.reverb)
      slot.delay.feedback = 28
      slot.reverb.loadFactoryPreset(.mediumHall)
      engine.connect(slot.player, to: slot.mixer, format: format)
      engine.connect(slot.mixer, to: slot.delay, format: format)
      engine.connect(slot.delay, to: slot.reverb, format: format)
      engine.connect(slot.reverb, to: loopsMixer, format: format)
      layerSlots.append(slot)
    }

    applyGains()
    installRecordTap()
    installSessionTap()
  }

  private func applyGains() {
    engine.mainMixerNode.outputVolume = masterGain
    metroMixer.outputVolume = metronomeOn ? metroGain : 0
    drumsMixer.outputVolume = drumsOn ? drumsGain : 0
    instMixer.outputVolume = instrumentGain
    instMixer.pan = instrumentPan
    instDelay.wetDryMix = instrumentDelay * 35
    instDelay.delayTime = min(1.85, max(0.08, 60 / Double(bpm) * 0.75))
    instReverb.wetDryMix = instrumentReverb * 40
    micMixer.outputVolume = (monitorOn && micArmed) ? micGain * 0.7 : 0
  }

  func setInstrumentPan(_ v: Float) { instrumentPan = v; rememberPatch(); applyGains() }
  func setInstrumentDelay(_ v: Float) { instrumentDelay = v; rememberPatch(); applyGains() }
  func setInstrumentReverb(_ v: Float) { instrumentReverb = v; rememberPatch(); applyGains() }
  func setInstrumentDrift(_ v: Float) { instrumentDrift = v; rememberPatch() }
  func setInstrumentRing(_ v: Float) { instrumentRing = v; rememberPatch() }
  func setInstrumentGlitch(_ v: Float) { instrumentGlitch = v; rememberPatch() }
  func setInstrumentTune(_ hz: Double) { instrumentTune = min(452, max(428, hz)); rememberPatch() }
  func setInstrumentOctave(_ n: Int) { instrumentOctave = min(3, max(-3, n)); rememberPatch() }

  func setMasterGain(_ v: Float) { masterGain = v; applyGains() }
  func setMetroGain(_ v: Float) { metroGain = v; applyGains() }
  func setDrumsGain(_ v: Float) { drumsGain = v; applyGains() }
  func setInstrumentGain(_ v: Float) { instrumentGain = v; rememberPatch(); applyGains() }
  func setMicGain(_ v: Float) { micGain = v; applyGains() }
  func setMetronomeOn(_ on: Bool) { metronomeOn = on; applyGains() }
  func setDrumsOn(_ on: Bool) {
    drumsOn = on
    applyGains()
    if running { rescheduleDrums() }
  }
  func setDrumId(_ id: String) {
    drumId = id
    if running { rescheduleDrums() }
  }
  func setPreset(_ p: InstrumentPreset) {
    rememberPatch()
    preset = p
    let patch = patches[p] ?? InstrumentPatch()
    instrumentGain = patch.gain
    instrumentPan = patch.pan
    instrumentDelay = patch.delay
    instrumentReverb = patch.reverb
    instrumentDrift = patch.drift
    instrumentRing = patch.ring
    instrumentGlitch = patch.glitch
    instrumentTune = patch.tune
    instrumentOctave = patch.octave
    applyGains()
  }

  private func rememberPatch() {
    patches[preset] = InstrumentPatch(
      gain: instrumentGain,
      pan: instrumentPan,
      delay: instrumentDelay,
      reverb: instrumentReverb,
      drift: instrumentDrift,
      ring: instrumentRing,
      glitch: instrumentGlitch,
      tune: instrumentTune,
      octave: instrumentOctave
    )
  }
  func setInputMode(_ mode: String) { inputMode = mode }
  func setCountInOn(_ on: Bool) { countInOn = on }
  func setMonitorOn(_ on: Bool) { monitorOn = on; applyGains() }
  func setBars(_ n: Int) {
    guard !loopLocked else { return }
    bars = n
  }
  func setBpm(_ n: Int) {
    guard !loopLocked else { return }
    bpm = min(220, max(40, n))
    applyGains()
  }
  func tapTempo(_ taps: [TimeInterval]) {
    guard !loopLocked, taps.count >= 2 else { return }
    var intervals: [TimeInterval] = []
    for i in 1..<taps.count { intervals.append(taps[i] - taps[i - 1]) }
    let avg = intervals.reduce(0, +) / Double(intervals.count)
    guard avg > 0 else { return }
    setBpm(Int((60 / avg).rounded()))
  }

  func play() {
    if status == .idle {
      beginCycle()
      status = .playing
    } else {
      stop()
    }
  }

  func stop() {
    capturing = false
    status = .idle
    position = 0
    drumsPlayer.stop()
    metroPlayer.stop()
    for layer in layers { layer.slot.player.stop() }
  }

  func record() {
    if status == .recording {
      // finish early — keep what we have if enough samples
      finishCapture(force: true)
      return
    }
    if status == .idle {
      if countInOn {
        status = .countin
        countInBeat = 0
        cycleStart = CACurrentMediaTime()
        scheduleMetro(countInOnly: true)
        return
      }
      beginCycle()
      startCapture()
      status = .recording
      return
    }
    if status == .playing {
      status = .armed
    }
  }

  func clear() {
    stop()
    for layer in layers {
      layer.slot.player.stop()
      layer.slot.busy = false
    }
    layers = []
    loopLocked = false
    layerSerial = 1
  }

  func noteOn(_ midi: Int, velocity: Float = 0.85) {
    guard unlocked, engine.isRunning else { return }
    noteOff(midi)
    guard let player = voicePool.popLast() else { return }
    busyVoices[midi] = player
    let buf = AudioDSP.renderNote(
      midi: midi,
      preset: preset,
      velocity: velocity,
      a4: instrumentTune,
      sampleRate: format.sampleRate,
      drift: instrumentDrift,
      ring: instrumentRing,
      glitch: instrumentGlitch
    )
    player.stop()
    if preset == .pluck {
      player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
    } else {
      player.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
    }
    player.volume = 1
    player.play()
  }

  func noteOff(_ midi: Int) {
    guard let player = busyVoices.removeValue(forKey: midi) else { return }
    player.stop()
    voicePool.append(player)
  }

  func enableMic() {
    micState = .pending
    Task {
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let granted: Bool
        if #available(iOS 17.0, *) {
          granted = await AVAudioApplication.requestRecordPermission()
        } else {
          granted = await withCheckedContinuation { cont in
            session.requestRecordPermission { cont.resume(returning: $0) }
          }
        }
        if !granted {
          micState = .denied
          return
        }
        if !micArmed {
          let input = engine.inputNode
          let inFormat = input.outputFormat(forBus: 0)
          if inFormat.sampleRate > 0, inFormat.channelCount > 0 {
            engine.connect(input, to: micMixer, format: inFormat)
          }
          micArmed = true
        }
        micState = .ready
        applyGains()
      } catch {
        micState = .error
        micError = error.localizedDescription
      }
    }
  }

  func setLayerGain(_ id: String, _ gain: Float) {
    if let i = layers.firstIndex(where: { $0.id == id }) {
      layers[i].gain = gain
      applyLayerMix(layers[i])
    }
  }

  func setLayerPan(_ id: String, _ pan: Float) {
    if let i = layers.firstIndex(where: { $0.id == id }) {
      layers[i].pan = pan
      applyLayerMix(layers[i])
    }
  }

  func setLayerDelay(_ id: String, _ delay: Float) {
    if let i = layers.firstIndex(where: { $0.id == id }) {
      layers[i].delay = delay
      applyLayerMix(layers[i])
    }
  }

  func setLayerReverb(_ id: String, _ reverb: Float) {
    if let i = layers.firstIndex(where: { $0.id == id }) {
      layers[i].reverb = reverb
      applyLayerMix(layers[i])
    }
  }

  func toggleMute(_ id: String) {
    if let i = layers.firstIndex(where: { $0.id == id }) {
      layers[i].muted.toggle()
      applyLayerMix(layers[i])
    }
  }

  func toggleReverse(_ id: String) {
    guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
    layers[i].reversed.toggle()
    rescheduleLayer(i)
  }

  func deleteLayer(_ id: String) {
    guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
    layers[i].slot.player.stop()
    layers[i].slot.busy = false
    layers.remove(at: i)
    if layers.isEmpty { loopLocked = false }
  }

  private func applyLayerMix(_ layer: Layer) {
    layer.slot.mixer.outputVolume = layer.muted ? 0 : layer.gain
    layer.slot.mixer.pan = layer.pan
    layer.slot.delay.wetDryMix = layer.delay * 35
    layer.slot.delay.delayTime = min(1.85, max(0.08, 60 / Double(bpm) * 0.75))
    layer.slot.reverb.wetDryMix = layer.reverb * 40
  }

  func startSessionRecord() {
    guard !sessionRecording else { return }
    sessionL = []
    sessionR = []
    sessionRecording = true
    sessionReady = false
    sessionURL = nil
    sessionStarted = CACurrentMediaTime()
    sessionElapsed = 0
  }

  func stopSessionRecord() {
    guard sessionRecording else { return }
    sessionRecording = false
    let n = min(sessionL.count, sessionR.count)
    guard n > 0 else { return }
    let buf = AudioDSP.makeBuffer(frames: n, sampleRate: format.sampleRate)
    let L = buf.floatChannelData![0]
    let R = buf.floatChannelData![1]
    for i in 0..<n {
      L[i] = sessionL[i]
      R[i] = sessionR[i]
    }
    let data = AudioDSP.encodeWav(buf)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("loopstack-session.wav")
    try? data.write(to: url)
    sessionURL = url
    sessionDuration = Double(n) / format.sampleRate
    sessionReady = true
  }

  func clearSession() {
    sessionReady = false
    sessionURL = nil
    sessionDuration = 0
  }

  func exportStems() -> URL? {
    guard !layers.isEmpty || drumsOn else { return nil }
    var files: [(String, Data)] = []
    if drumsOn {
      let pattern = DrumLibrary.find(drumId)
      let buf = AudioDSP.renderPattern(pattern, bpm: Double(bpm), loopBars: bars, sampleRate: format.sampleRate)
      files.append(("Drums - \(pattern.name).wav", AudioDSP.encodeWav(buf)))
    }
    for layer in layers {
      let src = layer.reversed ? layer.reverseBuffer : layer.buffer
      files.append(("\(layer.name).wav", AudioDSP.encodeWav(src)))
    }
    let readme = """
    Loopstack export

    Tempo: \(bpm) BPM
    Loop length: \(bars) bars (\(String(format: "%.2f", loopDuration))s)

    Every WAV is one loop cycle starting on the downbeat.
    """
    files.append(("README.txt", Data(readme.utf8)))
    let zip = AudioDSP.zipStore(files: files.map { (name: $0.0, data: $0.1) })
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("loopstack-\(bpm)bpm.zip")
    try? zip.write(to: url)
    return url
  }

  private func beginCycle() {
    cycleStart = CACurrentMediaTime()
    rescheduleDrums()
    rescheduleMetro()
    for i in layers.indices { rescheduleLayer(i) }
  }

  private func startClock() {
    clock?.invalidate()
    clock = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
  }

  private func tick() {
    audioRunning = engine.isRunning
    if sessionRecording {
      sessionElapsed = CACurrentMediaTime() - sessionStarted
    }
    guard running || status == .countin else {
      position = 0
      return
    }
    let now = CACurrentMediaTime()
    let dur = loopDuration
    if status == .countin {
      let elapsed = now - cycleStart
      countInBeat = min(3, Int(elapsed / (60 / Double(bpm))))
      if elapsed >= 60 / Double(bpm) * 4 {
        metroPlayer.stop()
        beginCycle()
        startCapture()
        status = .recording
      }
      return
    }
    let elapsed = now - cycleStart
    let pos = elapsed.truncatingRemainder(dividingBy: dur)
    position = pos / dur
    if status == .armed && pos < 0.04 && elapsed > 0.1 {
      startCapture()
      status = .recording
    }
    if capturing, capture.count >= captureTarget {
      finishCapture(force: false)
    }
  }

  private func startCapture() {
    capture = []
    captureTarget = Int(loopDuration * format.sampleRate)
    capturing = true
    loopLocked = true
  }

  private func finishCapture(force: Bool) {
    guard capturing else { return }
    capturing = false
    let n = min(capture.count, captureTarget)
    if n < Int(format.sampleRate * 0.2) && !force {
      status = .playing
      return
    }
    let frames = max(n, 1)
    let buf = AudioDSP.makeBuffer(frames: frames, sampleRate: format.sampleRate)
    let L = buf.floatChannelData![0]
    let R = buf.floatChannelData![1]
    for i in 0..<frames {
      let s = i < capture.count ? capture[i] : 0
      L[i] = s
      R[i] = s
    }
    guard let slot = layerSlots.first(where: { !$0.busy }) else {
      status = .playing
      return
    }
    slot.busy = true
    let layer = Layer(
      id: UUID().uuidString,
      name: "Loop \(layerSerial)",
      buffer: buf,
      reverseBuffer: AudioDSP.reverse(buf),
      peaks: AudioDSP.peaks(from: buf),
      gain: 0.9,
      pan: 0,
      delay: 0,
      reverb: 0,
      muted: false,
      reversed: false,
      slot: slot
    )
    layerSerial += 1
    layers.append(layer)
    applyLayerMix(layer)
    rescheduleLayer(layers.count - 1)
    status = .playing
  }

  private func rescheduleLayer(_ index: Int) {
    guard layers.indices.contains(index) else { return }
    let layer = layers[index]
    layer.slot.player.stop()
    let buf = layer.reversed ? layer.reverseBuffer : layer.buffer
    applyLayerMix(layer)
    if running {
      layer.slot.player.scheduleBuffer(buf, at: nil, options: .loops)
      layer.slot.player.play()
    }
  }

  private func rescheduleDrums() {
    drumsPlayer.stop()
    guard drumsOn, running else { return }
    let buf = AudioDSP.renderPattern(DrumLibrary.find(drumId), bpm: Double(bpm), loopBars: bars, sampleRate: format.sampleRate)
    drumsPlayer.scheduleBuffer(buf, at: nil, options: .loops)
    drumsPlayer.play()
  }

  private func rescheduleMetro() {
    metroPlayer.stop()
    guard running, metronomeOn else { return }
    let buf = AudioDSP.renderMetronome(bpm: Double(bpm), bars: bars, beatsPerBar: 4, sampleRate: format.sampleRate)
    metroPlayer.scheduleBuffer(buf, at: nil, options: .loops)
    metroPlayer.play()
  }

  private func scheduleMetro(countInOnly: Bool) {
    metroPlayer.stop()
    let buf = AudioDSP.renderMetronome(bpm: Double(bpm), bars: 1, beatsPerBar: 4, sampleRate: format.sampleRate)
    metroPlayer.scheduleBuffer(buf, at: nil, options: [])
    metroPlayer.play()
  }

  private func installRecordTap() {
    guard !tapInstalled else { return }
    tapInstalled = true
    instMixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      guard let self else { return }
      Task { @MainActor in
        guard self.capturing, let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        self.capture.reserveCapacity(self.capture.count + n)
        for i in 0..<n {
          if self.capture.count >= self.captureTarget { break }
          self.capture.append(ch[i])
        }
      }
    }
  }

  private func installSessionTap() {
    guard !sessionTapInstalled else { return }
    sessionTapInstalled = true
    sessionMixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      guard let self else { return }
      Task { @MainActor in
        guard self.sessionRecording else { return }
        let n = Int(buffer.frameLength)
        let chs = Int(buffer.format.channelCount)
        let lsrc = buffer.floatChannelData?[0]
        let rsrc = chs > 1 ? buffer.floatChannelData?[1] : lsrc
        guard let lsrc, let rsrc else { return }
        for i in 0..<n {
          self.sessionL.append(lsrc[i])
          self.sessionR.append(rsrc[i])
        }
      }
    }
  }
}
