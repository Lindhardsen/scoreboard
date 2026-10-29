import SwiftUI

/// Page 3: rename the teams with the watch keyboard, Scribble or dictation.
struct NamesView: View {
    @ObservedObject var store: ScoreStore
    @State private var drafts: [Side: String] = [:]

    var body: some View {
        Form {
            ForEach(Side.allCases, id: \.self) { side in
                Section(side == .home ? "Home" : "Away") {
                    TextField("Team name", text: binding(for: side))
                        .onSubmit { commit(side) }
                }
            }
        }
    }

    private func binding(for side: Side) -> Binding<String> {
        Binding(get: { drafts[side] ?? store.board[side].name },
                set: { drafts[side] = $0 })
    }

    private func commit(_ side: Side) {
        if let draft = drafts[side] {
            store.apply { $0.rename(side, to: draft) }
        }
        // Show the stored name again, trimmed or unchanged if the edit was rejected.
        drafts[side] = nil
    }
}
