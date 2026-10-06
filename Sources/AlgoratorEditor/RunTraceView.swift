import SwiftUI
import AlgoratorCore

/// Shows the outcome of a run: its status, outputs and the trace, one row per executed step.
public struct RunTraceView: View {
    public var result: RunResult

    public init(result: RunResult) {
        self.result = result
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(result.status.rawValue.capitalized)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .foregroundStyle(.white)
                    .background(statusColor, in: Capsule())
                ForEach(result.outputs.keys.sorted(), id: \.self) { name in
                    Text("\(name) = \(Coercion.toText(result.outputs[name] ?? .empty, in: RunEnvironment()))")
                        .font(.system(size: 11, design: .monospaced))
                }
                if let message = result.message {
                    Text(message).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(result.trace.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: step.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(step.succeeded ? Color.green : Color.red)
                            Text(step.label).font(.system(size: 12))
                            if let detail = step.message ?? step.note {
                                Text(detail).font(.system(size: 11)).foregroundStyle(step.succeeded ? Color.secondary : Color.red)
                            }
                        }
                        .padding(.leading, CGFloat(step.depth) * 18)
                    }
                    if result.trace.isEmpty {
                        Text("No steps were executed.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var statusColor: Color {
        switch result.status {
        case .completed, .returned: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}
