import SwiftUI
import Charts

/// Shown after a stream ends: how long it ran, who watched, and how chat went.
struct StreamSummaryView: View {
    let summary: StreamSummary
    let onDone: () -> Void

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                StatTile(label: "Duration", value: summary.formattedDuration)
                StatTile(label: "Peak viewers", value: format(summary.peakViewers))
                StatTile(label: "Avg viewers", value: format(summary.averageViewers))
                StatTile(label: "Chat messages", value: summary.messageCount.formatted())
                StatTile(label: "Chatters", value: summary.chatterCount.formatted())
                StatTile(
                    label: "Checklist",
                    value: summary.checklistTotal > 0 ? "\(summary.checklistDone)/\(summary.checklistTotal)" : "–"
                )
            }

            if summary.viewerSamples.count >= 2 {
                ViewerChart(samples: summary.viewerSamples)
            } else if summary.viewerSamples.isEmpty {
                Text("Connect YouTube or Twitch chat before going live to track viewers.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }

            if !summary.topChatters.isEmpty {
                topChatters
            }

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary.plainText, forType: .string)
                    didCopy = true
                } label: {
                    Label(didCopy ? "Copied" : "Copy Summary", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Color(white: 0.06))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stream ended")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text("\(summary.startedAt.formatted(date: .abbreviated, time: .shortened)) – \(summary.endedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var topChatters: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TOP CHATTERS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(1.5)

            ForEach(summary.topChatters) { chatter in
                HStack {
                    Text(chatter.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                    Spacer()
                    Text(chatter.count.formatted())
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private func format(_ value: Int?) -> String {
        guard let value else {
            return "–"
        }
        return value.formatted()
    }
}

private struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ViewerChart: View {
    let samples: [ViewerSample]

    @State private var selectedDate: Date?

    private var selected: ViewerSample? {
        guard let selectedDate else { return nil }
        return samples.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VIEWERS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(1.5)

            Chart {
                ForEach(samples) { sample in
                    AreaMark(x: .value("Time", sample.date), y: .value("Viewers", sample.viewers))
                        .foregroundStyle(.linearGradient(
                            colors: [.blue.opacity(0.25), .blue.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.date), y: .value("Viewers", sample.viewers))
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }

                if let selected {
                    RuleMark(x: .value("Time", selected.date))
                        .foregroundStyle(.white.opacity(0.25))
                    PointMark(x: .value("Time", selected.date), y: .value("Viewers", selected.viewers))
                        .foregroundStyle(.blue)
                        .symbolSize(64)
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            VStack(spacing: 1) {
                                Text(selected.viewers.formatted())
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                Text(selected.date.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color(white: 0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel().foregroundStyle(.white.opacity(0.4))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(height: 120)
        }
    }
}
