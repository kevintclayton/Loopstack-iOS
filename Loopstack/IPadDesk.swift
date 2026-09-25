import SwiftUI

/// iPad layout (regular width): two columns that scroll independently. Left is what you
/// play (transport, sound and pads); right is what you shape (loops, drums, mix, session).
/// Song mode uses the full width for its timeline. A narrow window (Split View, a small
/// resizable window) has compact width and gets the phone layout instead.
struct IPadDesk<Header: View, ModeSwitch: View, ExportRow: View>: View {
  @ObservedObject var engine: LoopEngine
  @Binding var showSong: Bool
  let header: Header
  let modeSwitch: ModeSwitch
  let exportRow: ExportRow

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .bottom, spacing: 24) {
        header
        modeSwitch
      }
      .padding(.horizontal, 24)
      .padding(.top, 12)

      if showSong {
        ScrollView {
          VStack(spacing: 16) {
            SongView(engine: engine, backToStack: { showSong = false })
            PrivacyView()
          }
          .frame(maxWidth: 980)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 24)
          .padding(.bottom, 40)
        }
      } else {
        HStack(alignment: .top, spacing: 20) {
          column(side: "left") {
            TransportView(engine: engine, openSong: { showSong = true })
            InstrumentView(engine: engine)
          }
          column(side: "right") {
            LayersView(engine: engine)
            DrumsView(engine: engine).id("drums")
            MixView(engine: engine).id("mix")
            SessionView(engine: engine, share: { SharePresenter.present($0) })
            exportRow
            PrivacyView()
          }
        }
        .padding(.horizontal, 24)
      }
    }
  }

  private func column<Content: View>(side: String, @ViewBuilder _ content: () -> Content) -> some View {
    let body = content()  // built here: the scroll reader's closure can't hold `content`
    return ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          body
        }
        .padding(.bottom, 40)
      }
      #if DEBUG
      // Screenshot demo: scroll this column to the scene's part.
      .onAppear { demoScroll(side, proxy) }
      .onChange(of: engine.demoScene) { _ in demoScroll(side, proxy) }
      #endif
    }
    .frame(maxWidth: .infinity)
  }

  #if DEBUG
  private func demoScroll(_ side: String, _ proxy: ScrollViewProxy) {
    let targets: [String: (String, String)] = [
      "synth": ("left", "synthpanel"), "drums": ("right", "drums"), "neon": ("right", "drums"), "mix": ("right", "mix"),
    ]
    guard let scene = engine.demoScene, let (col, id) = targets[scene], col == side else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { proxy.scrollTo(id, anchor: .top) }
  }
  #endif
}
