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
          column {
            TransportView(engine: engine, openSong: { showSong = true })
            InstrumentView(engine: engine)
          }
          column {
            LayersView(engine: engine)
            DrumsView(engine: engine)
            MixView(engine: engine)
            SessionView(engine: engine, share: { SharePresenter.present($0) })
            exportRow
            PrivacyView()
          }
        }
        .padding(.horizontal, 24)
      }
    }
  }

  private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        content()
      }
      .padding(.bottom, 40)
    }
    .frame(maxWidth: .infinity)
  }
}
