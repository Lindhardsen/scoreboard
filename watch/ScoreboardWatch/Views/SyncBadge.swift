import SwiftUI

struct SyncBadge: View {
    let status: SyncStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch status {
        case .synced: .green
        case .sending: .gray
        case .offline: .red
        }
    }

    private var label: String {
        switch status {
        case .synced: "Synced"
        case .sending: "Sending"
        case .offline: "Offline, retrying"
        }
    }
}

struct ScraperBanner: View {
    var body: some View {
        Text("Profixio scraper running — manual points will be overwritten")
            .font(.system(size: 11, weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(4)
            .frame(maxWidth: .infinity)
            .background(.red, in: RoundedRectangle(cornerRadius: 6))
    }
}
