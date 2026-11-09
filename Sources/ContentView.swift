import SwiftUI

struct ContentView: View {
    @ObservedObject var monitor = TemperatureMonitor.shared
    @AppStorage("unit") private var unitRaw = TempUnit.celsius.rawValue
    @State private var showSensors = true

    private var unit: TempUnit { TempUnit(rawValue: unitRaw) ?? .celsius }

    private var heat: Double {
        let t = max(monitor.cpu.current ?? 35, monitor.gpu.current ?? 35)
        return (t - 35) / 60      // 35 °C → 0, 95 °C → 1
    }

    var body: some View {
        ZStack {
            FlameBackground(heat: heat)
                .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35), .clear],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                header
                HStack(spacing: 20) {
                    TemperatureCard(title: "CPU", subtitle: monitor.chipName, symbol: "cpu",
                                    stats: monitor.cpu, unit: unit)
                    TemperatureCard(title: "GPU", subtitle: monitor.gpuName, symbol: "square.stack.3d.up.fill",
                                    stats: monitor.gpu, unit: unit)
                }
                if showSensors { SensorPanel(sensors: monitor.sensors, unit: unit) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.top, 38)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 46, height: 46)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.orange.opacity(0.35), lineWidth: 1))
                Image(systemName: "flame.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.flameGradient)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("TempMonitor")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(monitor.ready ? "Live · every \(intervalLabel) · \(monitor.architecture)" : "Discovering sensors…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            Spacer()
            RecordingControl(recorder: monitor.recorder)
            Picker("Interval", selection: $monitor.interval) {
                Text("0.5 s").tag(0.5)
                Text("1 s").tag(1.0)
                Text("2 s").tag(2.0)
                Text("5 s").tag(5.0)
            }
            .labelsHidden()
            .frame(width: 80)
            Picker("Unit", selection: $unitRaw) {
                ForEach(TempUnit.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 90)
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { showSensors.toggle() }
            } label: {
                Image(systemName: showSensors ? "list.bullet.circle.fill" : "list.bullet.circle")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .help("Show individual sensors")
            Button { monitor.resetSession() } label: {
                Image(systemName: "arrow.counterclockwise.circle").font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .help("Reset min / max")
        }
    }

    private var intervalLabel: String {
        monitor.interval < 1 ? String(format: "%.1fs", monitor.interval) : "\(Int(monitor.interval))s"
    }
}

// MARK: - Card

struct GlassCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.9)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.04)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }
}

struct TemperatureCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let stats: GroupStats
    let unit: TempUnit

    var body: some View {
        let tint = Theme.color(for: stats.current)
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(tint)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(tint.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(subtitle).font(.system(size: 11)).foregroundColor(.white.opacity(0.55)).lineLimit(1)
                    }
                    Spacer()
                    Text(Theme.status(for: stats.current).uppercased())
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(0.8)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(tint.opacity(0.18)))
                        .foregroundColor(tint)
                }

                HStack(alignment: .center, spacing: 18) {
                    RingGauge(value: stats.current, unit: unit)
                        .frame(width: 140, height: 140)
                    VStack(alignment: .leading, spacing: 10) {
                        StatRow(label: "Hottest sensor", value: unit.format(stats.hottest, decimals: 1))
                        StatRow(label: "Session max", value: unit.format(stats.sessionMax, decimals: 1))
                        StatRow(label: "Session min", value: unit.format(stats.sessionMin, decimals: 1))
                    }
                }

                Sparkline(values: stats.history, tint: tint)
                    .frame(height: 54)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: stats.current)
    }
}

struct StatRow: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.white.opacity(0.45))
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}

// MARK: - Gauge

struct RingGauge: View {
    let value: Double?
    let unit: TempUnit

    private var fraction: Double { min(1, max(0, (value ?? 0) / Theme.maxScale)) }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * fraction)
                .stroke(Theme.gaugeGradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(135))
                .shadow(color: Theme.color(for: value).opacity(0.7), radius: 8)
            VStack(spacing: 0) {
                Text(value.map { String(format: "%.0f", unit.convert($0)) } ?? "--")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(unit.rawValue)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .padding(6)
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let lo = (values.min() ?? 0) - 2
            let hi = (values.max() ?? 1) + 2
            let range = max(hi - lo, 1)
            let pts: [CGPoint] = values.enumerated().map { item -> CGPoint in
                let i = item.offset, v = item.element
                let x = values.count > 1 ? geo.size.width * CGFloat(i) / CGFloat(values.count - 1) : geo.size.width
                let y = geo.size.height * (1 - CGFloat((v - lo) / range))
                return CGPoint(x: x, y: y)
            }
            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.0)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                } else {
                    Text("Collecting history…")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

// MARK: - Sensor list

struct SensorPanel: View {
    let sensors: [SensorReading]
    let unit: TempUnit

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Sensors").font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Text("\(sensors.count) found")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                if sensors.isEmpty {
                    Text("No temperature sensors could be read on this Mac.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(sensors) { s in
                                SensorChip(sensor: s, unit: unit)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                }
            }
        }
    }
}

struct SensorChip: View {
    let sensor: SensorReading
    let unit: TempUnit

    var body: some View {
        let tint = Theme.color(for: sensor.value)
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 7, height: 7)
                .shadow(color: tint, radius: 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(sensor.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(sensor.group.rawValue).font(.system(size: 9)).foregroundColor(.white.opacity(0.45))
            }
            Spacer(minLength: 4)
            Text(unit.format(sensor.value, decimals: 1))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(tint)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Recording

struct RecordingControl: View {
    @ObservedObject var recorder: HistoryRecorder

    private var durationText: String {
        let t = Int(recorder.duration)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { recorder.isRecording.toggle() } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(recorder.isRecording ? Color.red : Color.white.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .shadow(color: recorder.isRecording ? .red : .clear, radius: 4)
                    Text(recorder.isRecording ? "REC" : "PAUSED")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(0.8)
                    Text(durationText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.65))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().stroke(recorder.isRecording ? Color.red.opacity(0.55) : Color.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(recorder.isRecording ? "Recording \(recorder.sampleCount) samples. Click to pause."
                                       : "Recording paused. Click to resume.")

            Menu {
                Button("Export History as CSV…") { recorder.exportWithPanel() }
                    .disabled(recorder.sampleCount == 0)
                Button("Export Graph as PNG…") { recorder.exportGraphWithPanel(.png) }
                    .disabled(recorder.sampleCount < 2)
                Button("Export Graph as PDF…") { recorder.exportGraphWithPanel(.pdf) }
                    .disabled(recorder.sampleCount < 2)
                Divider()
                Button("Open Saved Logs Folder") { recorder.openLogFolder() }
                Divider()
                Toggle("Record While Open", isOn: $recorder.isRecording)
                Toggle("Auto-save CSV + Graph When Quitting", isOn: $recorder.autoSaveOnQuit)
                Divider()
                Button("Clear History (\(recorder.sampleCount) samples)") { recorder.clear() }
                    .disabled(recorder.sampleCount == 0)
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Save recorded history")
        }
    }
}
