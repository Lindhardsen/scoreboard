import SwiftUI
import WatchKit

/// Page 1: tap a team to give it a point, long-press to take one back.
struct PointsView: View {
    @ObservedObject var store: ScoreStore

    var body: some View {
        if store.loaded {
            points
        } else {
            LoadingBoardView(store: store)
        }
    }

    private var points: some View {
        VStack(spacing: 4) {
            if store.scraperRunning {
                ScraperBanner()
            }
            ForEach(Side.allCases, id: \.self) { side in
                TeamPointsButton(team: store.board[side], serving: store.board.serving == side)
                    .accessibilityIdentifier("points-\(side.rawValue)")
                    .onTapGesture {
                        store.apply { $0.addPoint(side); return true }
                        WKInterfaceDevice.current().play(.click)
                    }
                    .onLongPressGesture(minimumDuration: 0.5) {
                        if store.apply({ $0.removePoint(side) }) {
                            WKInterfaceDevice.current().play(.directionDown)
                        }
                    }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                SyncBadge(status: store.status)
            }
        }
    }
}

private struct TeamPointsButton: View {
    let team: TeamState
    let serving: Bool

    var body: some View {
        let accent = TeamColor.color(from: team.colorStyle) ?? .gray
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(team.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(.yellow)
                    .frame(width: 8, height: 8)
                    .opacity(serving ? 1 : 0)
                    .accessibilityHidden(!serving)
            }
            Text("\(team.points)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(accent.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 4).padding(.vertical, 8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Tap to add a point, hold to remove one")
    }
}

/// Shown until the server's board is known, so nobody scores on a blank board.
struct LoadingBoardView: View {
    @ObservedObject var store: ScoreStore

    var body: some View {
        VStack(spacing: 8) {
            if store.status == .offline {
                Text("Can't load scoreboard")
                    .font(.headline)
                Button("Try again") {
                    Task { await store.refresh() }
                }
            } else {
                ProgressView()
                Text("Loading scoreboard…")
                    .font(.footnote)
            }
        }
    }
}
