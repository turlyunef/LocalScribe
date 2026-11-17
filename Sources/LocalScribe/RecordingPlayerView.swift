import SwiftUI
import LocalScribeCore

struct RecordingPlayerView: View {
    @ObservedObject var playback: RecordingPlayback
    let sourceAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if sourceAvailable {
                timeline
                controls
                switch playback.state {
                case .loading, .failed:
                    status
                case .idle, .ready:
                    EmptyView()
                }
            } else {
                Label(L10n.text("Аудио недоступно."), systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("playback.unavailable")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.25))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Аудиоплеер"))
        .accessibilityIdentifier("playback")
    }

    private var timeline: some View {
        let position = time(playback.position ?? 0)
        let duration = time(playback.duration)
        return HStack(spacing: 10) {
            Text(position).accessibilityHidden(true)
            Slider(value: Binding(
                get: { playback.position ?? 0 },
                set: { playback.seek(to: $0) }
            ), in: 0...max(0.001, playback.duration))
            .disabled(playback.duration <= 0)
            .accessibilityLabel(L10n.text("Позиция воспроизведения"))
            .accessibilityValue(L10n.text("%1$@ из %2$@", position, duration))
            .accessibilityIdentifier("playback.position")
            Text(duration).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .font(.caption.monospacedDigit())
        .controlSize(.small)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                transport
                options
                Spacer(minLength: 4)
                skipPauses
                follow
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    transport
                    options
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        skipPauses
                        follow
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        skipPauses
                        follow
                    }
                }
            }
        }
        .controlSize(.small)
    }

    private var transport: some View {
        HStack(spacing: 5) {
            skipButton(-1, icon: "gobackward")
            let title = L10n.text(playback.isPlaying ? "Пауза" : "Воспроизвести")
            Button(action: playback.toggle) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderedProminent)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityIdentifier("playback.toggle")
            skipButton(1, icon: "goforward")
        }
    }

    private func skipButton(_ direction: Int, icon: String) -> some View {
        let step = String(playback.skipSeconds)
        let title = L10n.text(direction < 0 ? "Назад на %1$@ с" : "Вперёд на %1$@ с", step)
        return Button { playback.skip(direction) } label: {
            Label(step, systemImage: icon)
                .font(.caption.monospacedDigit())
        }
        .disabled(playback.duration <= 0)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(direction < 0 ? "playback.back" : "playback.forward")
    }

    private var options: some View {
        HStack(spacing: 7) {
            Picker(L10n.text("Шаг"), selection: $playback.skipSeconds) {
                ForEach([5, 10], id: \.self) { step in
                    Text(L10n.text("%1$@ с", String(step))).tag(step)
                }
            }
            .fixedSize()
            .accessibilityIdentifier("playback.step")
            Picker(L10n.text("Скорость"), selection: $playback.speed) {
                ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { speed in
                    Text(speed.formatted(.number.locale(L10n.locale)) + "×").tag(speed)
                }
            }
            .fixedSize()
            .accessibilityIdentifier("playback.speed")
        }
    }

    private var skipPauses: some View {
        Toggle(L10n.text("Пропускать паузы"), isOn: $playback.skipsPauses)
            .toggleStyle(.checkbox)
            .font(.caption)
            .fixedSize()
            .accessibilityIdentifier("playback.skipPauses")
    }

    private var follow: some View {
        Toggle(L10n.text("Следовать за воспроизведением"), isOn: $playback.followsTranscript)
            .toggleStyle(.switch)
            .font(.caption)
            .fixedSize()
            .accessibilityIdentifier("playback.follow")
    }

    @ViewBuilder private var status: some View {
        switch playback.state {
        case .loading:
            ProgressView(L10n.text("Открываем аудио…")).font(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
        case .idle, .ready:
            EmptyView()
        }
    }

    private func time(_ seconds: Double) -> String {
        let formatted = timecode(Int(seconds * 1000))
        return seconds < 3600 ? String(formatted.dropFirst(3)) : formatted
    }
}
