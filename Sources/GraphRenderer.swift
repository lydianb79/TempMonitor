import AppKit
import UniformTypeIdentifiers

struct GraphPoint {
    let time: Date
    let cpu: Double?
    let gpu: Double?
    let cpuUsage: Double?
    let memUsage: Double?
}

/// Draws the recorded history with Core Graphics (PNG or PDF):
/// a temperature chart (CPU / GPU) and a usage chart (CPU / memory %) on a shared timeline.
enum GraphRenderer {
    static let size = CGSize(width: 1400, height: 1150)
    static let cpuColor = NSColor(srgbRed: 1.00, green: 0.55, blue: 0.16, alpha: 1)
    static let gpuColor = NSColor(srgbRed: 0.33, green: 0.78, blue: 1.00, alpha: 1)
    static let memColor = NSColor(srgbRed: 0.74, green: 0.52, blue: 1.00, alpha: 1)

    private struct Series {
        let name: String
        let color: NSColor
        let value: (GraphPoint) -> Double?
    }

    private struct Axis {
        let lo: Double
        let hi: Double
        let step: Double
        let label: (Double) -> String
        let unitLabel: String
    }

    private struct Timeline {
        let start: Date
        let end: Date
        let span: Double
        let gap: Double
        let tick: Double
        let tickFormatter: DateFormatter
    }

    // MARK: Output formats

    static func pngData(points: [GraphPoint], unit: TempUnit, chip: String, scale: CGFloat = 2) -> Data? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(in: ctx, points: points, unit: unit, chip: chip)
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func pdfData(points: [GraphPoint], unit: TempUnit, chip: String) -> Data? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        draw(in: ctx, points: points, unit: unit, chip: chip)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    // MARK: Page

    static func draw(in ctx: CGContext, points: [GraphPoint], unit: TempUnit, chip: String) {
        let W = size.width, H = size.height
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.current = previous }

        // Background: near-black with a warm glow from below
        if let bg = CGGradient(colorsSpace: nil, colors: [
            NSColor(srgbRed: 0.10, green: 0.07, blue: 0.08, alpha: 1).cgColor,
            NSColor(srgbRed: 0.03, green: 0.03, blue: 0.04, alpha: 1).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: .zero, options: [])
        }
        if let glow = CGGradient(colorsSpace: nil, colors: [
            NSColor(srgbRed: 1, green: 0.35, blue: 0.05, alpha: 0.12).cgColor,
            NSColor(srgbRed: 1, green: 0.35, blue: 0.05, alpha: 0).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: -80), startRadius: 0,
                                   endCenter: CGPoint(x: W / 2, y: -80), endRadius: W * 0.6, options: [])
        }

        guard let first = points.first, let last = points.last else { return }

        // Header
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "d MMM yyyy, HH:mm"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"
        let sameDay = Calendar.current.isDate(first.time, inSameDayAs: last.time)
        let range = "\(dayFmt.string(from: first.time)) – \(sameDay ? timeFmt.string(from: last.time) : dayFmt.string(from: last.time))"
        let subtitle = "\(chip)  ·  \(range)  ·  \(durationString(last.time.timeIntervalSince(first.time)))  ·  \(points.count) samples"
        text("Temperature & Usage", CGPoint(x: 48, y: H - 58), size: 28, weight: .bold, color: .white, rounded: true)
        text(subtitle, CGPoint(x: 48, y: H - 92), size: 13, weight: .medium, color: NSColor(white: 1, alpha: 0.55))

        let timeline = makeTimeline(points)

        // Panel 1: temperature
        let temps = points.flatMap { p in [p.cpu, p.gpu].compactMap { $0 } }.map(unit.convert)
        let tMin = temps.min() ?? 30, tMax = temps.max() ?? 90
        let spread = tMax - tMin
        let step: Double = spread <= 15 ? 5 : (spread <= 45 ? 10 : 20)
        let lo = floor((tMin - 2) / step) * step
        var hi = ceil((tMax + 2) / step) * step
        if hi - lo < step * 2 { hi = lo + step * 2 }
        let tempAxis = Axis(lo: lo, hi: hi, step: step, label: { String(format: "%.0f°", $0) }, unitLabel: unit.rawValue)
        drawPanel(ctx, title: "Temperature",
                  plot: CGRect(x: 84, y: 610, width: W - 132, height: H - 180 - 610),
                  points: points,
                  series: [Series(name: "CPU", color: cpuColor, value: { $0.cpu.map(unit.convert) }),
                           Series(name: "GPU", color: gpuColor, value: { $0.gpu.map(unit.convert) })],
                  axis: tempAxis, format: { String(format: "%.1f°", $0) }, timeline: timeline)

        // Panel 2: usage
        let usageAxis = Axis(lo: 0, hi: 100, step: 25, label: { String(format: "%.0f%%", $0) }, unitLabel: "%")
        drawPanel(ctx, title: "Usage",
                  plot: CGRect(x: 84, y: 90, width: W - 132, height: 400),
                  points: points,
                  series: [Series(name: "CPU", color: cpuColor, value: { $0.cpuUsage }),
                           Series(name: "Memory", color: memColor, value: { $0.memUsage })],
                  axis: usageAxis, format: { String(format: "%.0f%%", $0) }, timeline: timeline)

        // Footer
        let made = DateFormatter(); made.dateFormat = "d MMM yyyy HH:mm"
        text("TempMonitor  ·  exported \(made.string(from: Date()))", CGPoint(x: W - 48, y: 24), size: 11,
             weight: .medium, color: NSColor(white: 1, alpha: 0.35), align: .right)
    }

    private static func makeTimeline(_ points: [GraphPoint]) -> Timeline {
        let start = points.first!.time, end = points.last!.time
        let span = max(1, end.timeIntervalSince(start))

        // Break lines where recording was paused
        var diffs: [Double] = []
        if points.count > 1 {
            for i in 1..<min(points.count, 2000) { diffs.append(points[i].time.timeIntervalSince(points[i - 1].time)) }
        }
        diffs.sort()
        let median = diffs.isEmpty ? 1 : diffs[diffs.count / 2]

        let candidates: [Double] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800]
        let tick = candidates.first { span / $0 <= 8 } ?? 172800
        let f = DateFormatter()
        f.dateFormat = tick < 60 ? "HH:mm:ss" : (span > 86400 ? "d MMM HH:mm" : "HH:mm")
        return Timeline(start: start, end: end, span: span, gap: max(10, median * 5), tick: tick, tickFormatter: f)
    }

    // MARK: Panel

    private static func drawPanel(_ ctx: CGContext, title: String, plot: CGRect, points: [GraphPoint],
                                  series: [Series], axis: Axis, format: (Double) -> String, timeline: Timeline) {
        let W = size.width
        func px(_ t: Date) -> CGFloat { plot.minX + CGFloat(t.timeIntervalSince(timeline.start) / timeline.span) * plot.width }
        func py(_ v: Double) -> CGFloat {
            plot.minY + CGFloat((min(max(v, axis.lo), axis.hi) - axis.lo) / (axis.hi - axis.lo)) * plot.height
        }

        // Panel background
        ctx.setFillColor(NSColor(white: 1, alpha: 0.03).cgColor)
        ctx.addPath(CGPath(roundedRect: plot.insetBy(dx: -12, dy: -12), cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()

        // Title + legend on one line
        let titleY = plot.maxY + 42
        text(title, CGPoint(x: 48, y: titleY), size: 17, weight: .bold, color: .white, rounded: true)
        var cursor = W - 48
        for s in series.reversed() {
            let vals = points.compactMap(s.value)
            guard !vals.isEmpty else { continue }
            let avg = vals.reduce(0, +) / Double(vals.count)
            let stats = "avg \(format(avg))  max \(format(vals.max()!))  min \(format(vals.min()!))"
            let statsW = attributed(stats, size: 12, weight: .medium, color: .white, mono: true).size().width
            text(stats, CGPoint(x: cursor, y: titleY), size: 12, weight: .medium,
                 color: NSColor(white: 1, alpha: 0.75), align: .right, mono: true)
            cursor -= statsW + 10
            let nameW = attributed(s.name, size: 12, weight: .bold, color: .white).size().width
            text(s.name, CGPoint(x: cursor, y: titleY), size: 12, weight: .bold, color: s.color, align: .right)
            cursor -= nameW + 8
            ctx.setFillColor(s.color.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: cursor - 20, y: titleY - 2, width: 20, height: 4),
                               cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            cursor -= 20 + 30
        }

        // Horizontal grid + Y labels
        ctx.setLineWidth(1)
        for v in stride(from: axis.lo, through: axis.hi + 0.001, by: axis.step) {
            let y = py(v)
            ctx.setStrokeColor(NSColor(white: 1, alpha: v == axis.lo ? 0.22 : 0.08).cgColor)
            ctx.move(to: CGPoint(x: plot.minX, y: y)); ctx.addLine(to: CGPoint(x: plot.maxX, y: y)); ctx.strokePath()
            text(axis.label(v), CGPoint(x: plot.minX - 14, y: y), size: 12, weight: .medium,
                 color: NSColor(white: 1, alpha: 0.5), align: .right, mono: true)
        }
        text(axis.unitLabel, CGPoint(x: plot.minX - 14, y: plot.maxY + 18), size: 11, weight: .semibold,
             color: NSColor(white: 1, alpha: 0.4), align: .right)

        // Vertical grid + time labels
        let offset = Double(TimeZone.current.secondsFromGMT(for: timeline.start))
        var t = ceil((timeline.start.timeIntervalSince1970 + offset) / timeline.tick) * timeline.tick - offset
        while t <= timeline.end.timeIntervalSince1970 {
            let date = Date(timeIntervalSince1970: t)
            let x = px(date)
            ctx.saveGState()
            ctx.setLineDash(phase: 0, lengths: [3, 5])
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.07).cgColor)
            ctx.move(to: CGPoint(x: x, y: plot.minY)); ctx.addLine(to: CGPoint(x: x, y: plot.maxY)); ctx.strokePath()
            ctx.restoreGState()
            text(timeline.tickFormatter.string(from: date), CGPoint(x: x, y: plot.minY - 26), size: 12, weight: .medium,
                 color: NSColor(white: 1, alpha: 0.5), align: .center, mono: true)
            t += timeline.tick
        }

        // Series
        func segments(_ value: (GraphPoint) -> Double?) -> [[CGPoint]] {
            var segs: [[CGPoint]] = []
            var cur: [CGPoint] = []
            var count: CGFloat = 0
            var prevTime: Date?
            for p in points {
                guard let v = value(p) else {
                    if !cur.isEmpty { segs.append(cur); cur = [] }
                    prevTime = nil
                    continue
                }
                if let pt = prevTime, p.time.timeIntervalSince(pt) > timeline.gap, !cur.isEmpty { segs.append(cur); cur = [] }
                prevTime = p.time
                let x = px(p.time), y = py(v)
                if let lastPt = cur.last, x - lastPt.x < 0.75 {      // merge samples on the same pixel column
                    cur[cur.count - 1].y = (lastPt.y * count + y) / (count + 1)
                    count += 1
                } else {
                    cur.append(CGPoint(x: x, y: y))
                    count = 1
                }
            }
            if !cur.isEmpty { segs.append(cur) }
            return segs
        }

        ctx.saveGState()
        ctx.clip(to: plot.insetBy(dx: -4, dy: -4))
        for s in series.reversed() {
            for seg in segments(s.value) {
                if seg.count == 1 {
                    ctx.setFillColor(s.color.cgColor)
                    ctx.fillEllipse(in: CGRect(x: seg[0].x - 2, y: seg[0].y - 2, width: 4, height: 4))
                    continue
                }
                let area = CGMutablePath()
                area.move(to: CGPoint(x: seg[0].x, y: plot.minY))
                seg.forEach { area.addLine(to: $0) }
                area.addLine(to: CGPoint(x: seg[seg.count - 1].x, y: plot.minY))
                area.closeSubpath()
                if let g = CGGradient(colorsSpace: nil, colors: [s.color.withAlphaComponent(0.20).cgColor,
                                                                 s.color.withAlphaComponent(0.0).cgColor] as CFArray,
                                      locations: [0, 1]) {
                    ctx.saveGState()
                    ctx.addPath(area); ctx.clip()
                    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: plot.maxY), end: CGPoint(x: 0, y: plot.minY), options: [])
                    ctx.restoreGState()
                }
                let line = CGMutablePath()
                line.addLines(between: seg)
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 8, color: s.color.withAlphaComponent(0.6).cgColor)
                ctx.addPath(line)
                ctx.setStrokeColor(s.color.cgColor)
                ctx.setLineWidth(2.4)
                ctx.setLineJoin(.round); ctx.setLineCap(.round)
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()

        // Peak markers
        for s in series.reversed() {
            var best: (time: Date, value: Double)?
            for p in points { if let v = s.value(p), v > (best?.value ?? -.infinity) { best = (p.time, v) } }
            guard let peak = best else { continue }
            let pt = CGPoint(x: px(peak.time), y: py(peak.value))
            ctx.setFillColor(s.color.cgColor)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2)
            let r = CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)
            ctx.fillEllipse(in: r); ctx.strokeEllipse(in: r)
            let align: NSTextAlignment = pt.x > plot.maxX - 80 ? .right : (pt.x < plot.minX + 80 ? .left : .center)
            text("peak \(format(peak.value))", CGPoint(x: pt.x, y: min(pt.y + 18, plot.maxY + 4)),
                 size: 11, weight: .bold, color: s.color, align: align, mono: true)
        }
    }

    // MARK: Helpers

    private static func durationString(_ s: TimeInterval) -> String {
        let t = Int(s)
        if t >= 3600 { return "\(t / 3600)h \((t / 60) % 60)m" }
        if t >= 60 { return "\(t / 60)m \(t % 60)s" }
        return "\(t)s"
    }

    private static func attributed(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
                                   mono: Bool = false, rounded: Bool = false) -> NSAttributedString {
        var font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                        : NSFont.systemFont(ofSize: size, weight: weight)
        if rounded, let d = font.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { font = f }
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    /// Draws text vertically centred on `p.y`.
    private static func text(_ s: String, _ p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
                             color: NSColor, align: NSTextAlignment = .left, mono: Bool = false, rounded: Bool = false) {
        let str = attributed(s, size: size, weight: weight, color: color, mono: mono, rounded: rounded)
        let sz = str.size()
        var o = CGPoint(x: p.x, y: p.y - sz.height / 2)
        if align == .right { o.x -= sz.width } else if align == .center { o.x -= sz.width / 2 }
        str.draw(at: o)
    }
}

// MARK: - Export from the recorder

extension HistoryRecorder {
    enum GraphFormat {
        case png, pdf
        var type: UTType { self == .png ? .png : .pdf }
        var fileExtension: String { self == .png ? "png" : "pdf" }
    }

    private func graphData(_ format: GraphFormat) -> Data? {
        let unit = TempUnit(rawValue: UserDefaults.standard.string(forKey: "unit") ?? "") ?? .celsius
        let points = rows.map { GraphPoint(time: $0.time, cpu: $0.cpu, gpu: $0.gpu,
                                              cpuUsage: $0.cpuUsage, memUsage: $0.memUsage) }
        let chip = TemperatureMonitor.shared.chipName
        switch format {
        case .png: return GraphRenderer.pngData(points: points, unit: unit, chip: chip)
        case .pdf: return GraphRenderer.pdfData(points: points, unit: unit, chip: chip)
        }
    }

    func exportGraphWithPanel(_ format: GraphFormat) {
        guard rows.count >= 2 else { NSSound.beep(); return }
        try? FileManager.default.createDirectory(at: Self.logFolder, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.title = "Export Temperature Graph"
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = "\(fileBaseName).\(format.fileExtension)"
        panel.directoryURL = Self.logFolder
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let data = graphData(format) else { return }
        do {
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSLog("TempMonitor: could not save graph: \(error)")
            NSSound.beep()
        }
    }

    /// Writes a PNG graph next to the auto-saved CSV.
    func autoSaveGraph() {
        guard rows.count >= 2, let data = graphData(.png) else { return }
        try? data.write(to: Self.logFolder.appendingPathComponent("\(fileBaseName).png"), options: .atomic)
    }
}
