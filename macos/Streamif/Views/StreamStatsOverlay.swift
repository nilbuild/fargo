import SwiftUI

struct StreamStatsOverlay: View {
    let streamManager: StreamManager
    let onClose: () -> Void
    @State private var healthData: [UUID: RTMPClient.StreamHealth] = [:]
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 9, weight: .bold))
                Text("STREAM STATS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 16, height: 16)
                        .background(.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white.opacity(0.5))

            let destinations = streamManager.destinations
            if destinations.isEmpty {
                Text("No active destinations")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ForEach(destinations, id: \.id) { dest in
                    let h = healthData[dest.id] ?? RTMPClient.StreamHealth()
                    destinationStats(dest, health: h)
                }
            }
        }
        .padding(10)
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 2)
        .onAppear {
            healthData = streamManager.aggregateHealth
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in
                    healthData = streamManager.aggregateHealth
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    @ViewBuilder
    private func destinationStats(_ dest: any StreamOutput, health: RTMPClient.StreamHealth) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(stateColor(dest.connectionState))
                    .frame(width: 5, height: 5)
                Text(shortName(dest.destinationName))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)

                if case .reconnecting(let n) = dest.connectionState {
                    Text("retry \(n)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.yellow)
                }
            }

            HStack(spacing: 12) {
                statItem("BR", formatBitrate(health.currentBitrate))
                statItem("Q", formatBytes(health.queuedBytes))
                statItem("DROP", "\(health.droppedFrames)/\(health.totalFrames)")
                if health.uptimeSeconds > 0 {
                    statItem("UP", formatUptime(health.uptimeSeconds))
                }
            }

            if health.dropRate > 0.05 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                    Text("High drop rate: \(Int(health.dropRate * 100))%")
                        .font(.system(size: 9, design: .monospaced))
                }
                .foregroundStyle(.yellow)
            }
        }
    }

    private func statItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private func stateColor(_ state: RTMPClient.ClientState) -> Color {
        switch state {
        case .live: return .green
        case .connecting: return .yellow
        case .reconnecting: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private func shortName(_ url: String) -> String {
        guard let host = URL(string: url)?.host else { return url }
        let parts = host.split(separator: ".")
        if parts.count >= 2 {
            return String(parts[parts.count - 2]).capitalized
        }
        return host
    }

    private func formatBitrate(_ bps: Int) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.1fM", Double(bps) / 1_000_000)
        }
        return "\(bps / 1000)k"
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1fMB", Double(bytes) / 1_000_000)
        }
        if bytes >= 1000 {
            return "\(bytes / 1000)KB"
        }
        return "\(bytes)B"
    }

    private func formatUptime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
