import AppKit
import UniformTypeIdentifiers

struct GraphPoint {
    let time: Date
    let cpu: Double?
    let gpu: Double?
}

/// Draws the recorded history as a chart with Core Graphics (PNG or PDF).
enum GraphRenderer {
    static let size = CGSize(width: 1400, height: 800)
    static let cpuColor = NSColor(srgbRed: 1.00, green: 0.55, blue: 0.16, alpha: 1)
    static let gpuColor = NSColor(srgbRed: 0.33, green: 0.78, blue: 1.00, alpha: 1)

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

    // MARK: Drawing

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
            NSColor(srgbRed: 1, green: 0.35, blue: 0.05, alpha: 0.14).cgColor,
            NSColor(srgbRed: 1, green: 0.35, blue: 0.05, alpha: 0).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: -80), startRadius: 0,
                                   endCenter: CGPoint(x: W / 2, y: -80), endRadius: W * 0.6, options: [])
        }

        guard let first = points.first, let last = points.last else { return }
        let cpuVals = points.compactMap { $0.cpu }.map(unit.convert)
        let gpuVals = points.compactMap { $0.gpu }.map(unit.convert)
        let all = cpuVals + gpuVals
        guard let vMin = all.min(), let vMax = all.max() else { return }

        // Header
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "d MMM yyyy, HH:mm"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"
        let sameDay = Calendar.current.isDate(first.time, inSameDayAs: last.time)
        let range = "\(dayFmt.string(from: first.time)) – \(sameDay ? timeFmt.string(from: last.time) : dayFmt.string(from: last.time))"
        let subtitle = "\(chip)  ·  \(range)  ·  \(durationString(last.time.timeIntervalSince(first.time)))  ·  \(points.count) samples"

        text("CPU & GPU Temperature", CGPoint(x: 48, y: H - 58), size: 28, weight: .bold, color: .white, rounded: true)
        text(subtitle, CGPoint(x: 48, y: H - 92), size: 13, weight: .medium, color: NSColor(white: 1, alpha: 0.55))

        var legendY = H - 58
        for (name, vals, color) in [("CPU", cpuVals, cpuColor), ("GPU", gpuVals, gpuColor)] where !vals.isEmpty {
            let avg = vals.reduce(0, +) / Double(vals.count)
            let stats = "avg \(fmt(avg))   max \(fmt(vals.max()!))   min \(fmt(vals.min()!))"
            let statsWidth = attributed(stats, size: 13, weight: .medium, color: .white, mono: true).size().width
            text(stats, CGPoint(x: W - 48, y: legendY), size: 13, weight: .medium,
                 color: NSColor(white: 1, alpha: 0.8), align: .right, mono: true)
            let labelX = W - 48 - statsWidth - 16
            text(name, CGPoint(x: labelX, y: legendY), size: 13, weight: .bold, color: color, align: .right)
            let swatch = CGRect(x: labelX - 50, y: legendY - 2, width: 22, height: 4)
            ctx.setFillColor(color.cgColor)
            ctx.addPath(CGPath(roundedRect: swatch, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            legendY -= 26
        }

        // Plot geometry
        let plot = CGRect(x: 84, y: 70, width: W - 84 - 48, height: H - 70 - 150)
        let span = max(1, last.time.timeIntervalSince(first.time))
        let spread = vMax - vMin
        let step: Double = spread <= 15 ? 5 : (spread <= 45 ? 10 : 20)
        let lo = floor((vMin - 2) / step) * step
        var hi = ceil((vMax + 2) / step) * step
        if hi - lo < step * 2 { hi = lo + step * 2 }
        func px(_ t: Date) -> CGFloat { plot.minX + CGFloat(t.timeIntervalSince(first.time) / span) * plot.width }
        func py(_ v: Double) -> CGFloat { plot.minY + CGFloat((v - lo) / (hi - lo)) * plot.height }

        // Plot panel
        ctx.setFillColor(NSColor(white: 1, alpha: 0.03).cgColor)
        ctx.addPath(CGPath(roundedRect: plot.insetBy(dx: -12, dy: -12), cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()

        // Horizontal grid + Y labels
        ctx.setLineWidth(1)
        for v in stride(from: lo, through: hi + 0.001, by: step) {
            let y = py(v)
            ctx.setStrokeColor(NSColor(white: 1, alpha: v == lo ? 0.22 : 0.08).cgColor)
            ctx.move(to: CGPoint(x: plot.minX, y: y)); ctx.addLine(to: CGPoint(x: plot.maxX, y: y)); ctx.strokePath()
            text(String(format: "%.0f°", v), CGPoint(x: plot.minX - 14, y: y), size: 12, weight: .medium,
                 color: NSColor(white: 1, alpha: 0.5), align: .right, mono: true)
        }
        text(unit.rawValue, CGPoint(x: plot.minX - 14, y: plot.maxY + 26), size: 11, weight: .semibold,
             color: NSColor(white: 1, alpha: 0.4), align: .right)

        // Vertical grid + time labels
        let candidates: [Double] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800]
        let tick = candidates.first { span / $0 <= 8 } ?? 172800
        let tickFmt = DateFormatter()
        tickFmt.dateFormat = tick < 60 ? "HH:mm:ss" : (span > 86400 ? "d MMM HH:mm" : "HH:mm")
        let offset = Double(TimeZone.current.secondsFromGMT(for: first.time))
        var t = ceil((first.time.timeIntervalSince1970 + offset) / tick) * tick - offset
        let dash: [CGFloat] = [3, 5]
        while t <= last.time.timeIntervalSince1970 {
            let date = Date(timeIntervalSince1970: t)
            let x = px(date)
            ctx.saveGState()
            ctx.setLineDash(phase: 0, lengths: dash)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.07).cgColor)
            ctx.move(to: CGPoint(x: x, y: plot.minY)); ctx.addLine(to: CGPoint(x: x, y: plot.maxY)); ctx.strokePath()
            ctx.restoreGState()
            text(tickFmt.string(from: date), CGPoint(x: x, y: plot.minY - 26), size: 12, weight: .medium,
                 color: NSColor(white: 1, alpha: 0.5), align: .center, mono: true)
            t += tick
        }

        // Gap threshold: break lines where recording was paused
        var diffs: [Double] = []
        for i in 1..<min(points.count, 2000) { diffs.append(points[i].time.timeIntervalSince(points[i - 1].time)) }
        diffs.sort()
        let median = diffs.isEmpty ? 1 : diffs[diffs.count / 2]
        let gap = max(10, median * 5)

        func segments(_ value: (GraphPoint) -> Double?) -> [[CGPoint]] {
            var segs: [[CGPoint]] = []
            var cur: [CGPoint] = []
            var count: CGFloat = 0
            var prevTime: Date?
            for p in points {
                guard let raw = value(p) else {
                    if !cur.isEmpty { segs.append(cur); cur = [] }
                    prevTime = nil
                    continue
                }
                if let pt = prevTime, p.time.timeIntervalSince(pt) > gap, !cur.isEmpty { segs.append(cur); cur = [] }
                prevTime = p.time
                let x = px(p.time), y = py(unit.convert(raw))
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

        func drawSeries(_ segs: [[CGPoint]], color: NSColor) {
            ctx.saveGState()
            ctx.clip(to: plot.insetBy(dx: -4, dy: -4))
            for seg in segs {
                if seg.count == 1 {
                    ctx.setFillColor(color.cgColor)
                    ctx.fillEllipse(in: CGRect(x: seg[0].x - 2, y: seg[0].y - 2, width: 4, height: 4))
                    continue
                }
                // gradient fill under the line
                let area = CGMutablePath()
                area.move(to: CGPoint(x: seg[0].x, y: plot.minY))
                seg.forEach { area.addLine(to: $0) }
                area.addLine(to: CGPoint(x: seg[seg.count - 1].x, y: plot.minY))
                area.closeSubpath()
                if let g = CGGradient(colorsSpace: nil, colors: [color.withAlphaComponent(0.22).cgColor,
                                                                 color.withAlphaComponent(0.0).cgColor] as CFArray,
                                      locations: [0, 1]) {
                    ctx.saveGState()
                    ctx.addPath(area); ctx.clip()
                    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: plot.maxY), end: CGPoint(x: 0, y: plot.minY), options: [])
                    ctx.restoreGState()
                }
                // line with soft glow
                let line = CGMutablePath()
                line.addLines(between: seg)
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 8, color: color.withAlphaComponent(0.6).cgColor)
                ctx.addPath(line)
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(2.4)
                ctx.setLineJoin(.round); ctx.setLineCap(.round)
                ctx.strokePath()
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }

        func markPeak(_ value: (GraphPoint) -> Double?, color: NSColor) {
            var best: (Date, Double)?
            for p in points { if let v = value(p), v > (best?.1 ?? -.infinity) { best = (p.time, v) } }
            guard let peak = best else { return }
            let time = peak.0, raw = peak.1
            let pt = CGPoint(x: px(time), y: py(unit.convert(raw)))
            ctx.setFillColor(color.cgColor)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2)
            let r = CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)
            ctx.fillEllipse(in: r); ctx.strokeEllipse(in: r)
            let align: NSTextAlignment = pt.x > plot.maxX - 80 ? .right : (pt.x < plot.minX + 80 ? .left : .center)
            text("peak \(fmt(unit.convert(raw)))", CGPoint(x: pt.x, y: min(pt.y + 18, plot.maxY + 8)),
                 size: 11, weight: .bold, color: color, align: align, mono: true)
        }

        drawSeries(segments { $0.gpu }, color: gpuColor)
        drawSeries(segments { $0.cpu }, color: cpuColor)
        markPeak({ $0.gpu }, color: gpuColor)
        markPeak({ $0.cpu }, color: cpuColor)

        // Footer
        let made = DateFormatter(); made.dateFormat = "d MMM yyyy HH:mm"
        text("TempMonitor  ·  exported \(made.string(from: Date()))", CGPoint(x: W - 48, y: 24), size: 11,
             weight: .medium, color: NSColor(white: 1, alpha: 0.35), align: .right)
    }

    // MARK: Helpers

    private static func fmt(_ v: Double) -> String { String(format: "%.1f°", v) }

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
        let points = rows.map { GraphPoint(time: $0.time, cpu: $0.cpu, gpu: $0.gpu) }
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
