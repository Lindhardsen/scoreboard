import SwiftUI
import WatchKit

/// Page 2: set counts, new set, reset match, and the way back to sign-in settings.
struct SetsView: View {
    @ObservedObject var store: ScoreStore
    @State private var pendingSet: Side?
    @State private var confirmingReset = false
    @State private var showingSettings = false

    var body: some View {
        if store.loaded {
            sets
        } else {
            LoadingBoardView(store: store)
        }
    }

    private var sets: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(Side.allCases, id: \.self) { side in
                    SetRow(team: store.board[side],
                           onMinus: {
                               if store.apply({ $0.removeSet(side) }) {
                                   WKInterfaceDevice.current().play(.directionDown)
                               }
                           },
                           onPlus: { pendingSet = side })
                }
                Button("Reset match", role: .destructive) { confirmingReset = true }
                    .padding(.top, 4)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .confirmationDialog("Start next set at 0–0?",
                            isPresented: Binding(get: { pendingSet != nil }, set: { if !$0 { pendingSet = nil } }),
                            titleVisibility: .visible) {
            Button("Yes") { addSet(resetPoints: true) }
            Button("No") { addSet(resetPoints: false) }
        }
        .confirmationDialog("Reset the match?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                store.apply { $0.reset(); return true }
                WKInterfaceDevice.current().play(.failure)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(store: store)
        }
    }

    private func addSet(resetPoints: Bool) {
        guard let side = pendingSet else { return }
        pendingSet = nil
        store.apply { $0.addSet(side, resetPoints: resetPoints); return true }
        WKInterfaceDevice.current().play(.success)
    }
}

private struct SetRow: View {
    let team: TeamState
    let onMinus: () -> Void
    let onPlus: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Text(team.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(action: onMinus) { Image(systemName: "minus") }
                    .accessibilityLabel("Remove set from \(team.name)")
                Text("\(team.sets)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 36)
                Button(action: onPlus) { Image(systemName: "plus") }
                    .accessibilityLabel("Add set to \(team.name)")
            }
        }
    }
}

private struct SettingsSheet: View {
    @ObservedObject var store: ScoreStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let creds = store.credentials {
                    Text(creds.server.absoluteString).font(.footnote)
                    Text(creds.username).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Sign out", role: .destructive) {
                    dismiss()
                    store.signOut()
                }
            }
        }
    }
}
