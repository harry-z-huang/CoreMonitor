import SwiftUI
import IOKit
import Darwin

// MARK: - Sampling
final class Monitor: ObservableObject {
    static let historyLen = 60
    @Published var cpu: [[Double]] = []          // per core history 0...1
    @Published var cpuSys: [Double] = Array(repeating: 0, count: Monitor.historyLen)   // whole-chip, 0...1
    @Published var cpuUser: [Double] = Array(repeating: 0, count: Monitor.historyLen)
    /// CPU view mode, shared by the Graphs page and the Processes summary; remembered across launches.
    @Published var cpuCombined = UserDefaults.standard.bool(forKey: "cpuCombined") { didSet { UserDefaults.standard.set(cpuCombined, forKey: "cpuCombined") } }
    @Published var gpu: [String: [Double]] = [:] // metric -> history
    @Published var gpuMemGB: Double = 0
    @Published var gpuMemHist: [Double] = Array(repeating: 0, count: Monitor.historyLen)
    let totalMemGB: Double = { var v: UInt64 = 0; var s = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &v, &s, nil, 0); return Double(v) / 1_073_741_824 }()
    @Published var gpuCores = 0
    let pCores = sysctlInt("hw.perflevel0.logicalcpu")
    let eCores = sysctlInt("hw.perflevel1.logicalcpu")
    let gpuKeys = ["Device Utilization %", "Renderer Utilization %", "Tiler Utilization %"]
    private var prevTicks: [[UInt32]] = []
    private let chipTemp = ChipTemp()
    /// The IOHID temperature read takes ~15 ms, so it runs here instead of stalling the main thread every second.
    private let tempQ = DispatchQueue(label: "chiptemp", qos: .utility)
    private var tempBusy = false
    @Published var chipC: Double? = nil
    // Memory: GB histories; CPU = used memory not attributed to the GPU
    @Published var memGPU: [Double] = Array(repeating: 0, count: Monitor.historyLen)
    @Published var memCPU: [Double] = Array(repeating: 0, count: Monitor.historyLen)
    @Published var memApp = 0.0
    @Published var memWired = 0.0
    @Published var memCompressed = 0.0
    @Published var memCached = 0.0
    @Published var memFree = 0.0
    @Published var swapUsed = 0.0
    // name -> (read history, write history) in bytes/sec
    @Published var disks: [(name: String, read: [Double], write: [Double])] = []
    @Published var nets: [(name: String, label: String, down: [Double], up: [Double])] = []
    private let netNames = NetNames()
    private var prevDisk: [String: (UInt64, UInt64)] = [:]
    private var prevNet: [String: (UInt64, UInt64)] = [:]
    private var lastIOTime = Date()
    private var timer: Timer?

    init() {
        for k in gpuKeys { gpu[k] = Array(repeating: 0, count: Self.historyLen) }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
    }

    static func sysctlInt(_ name: String) -> Int {
        var v: Int32 = 0; var s = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &s, nil, 0) == 0 ? Int(v) : 0
    }

    func sample() {
        sampleCPU(); sampleGPU(); sampleMemory()
        if !tempBusy {
            tempBusy = true
            tempQ.async { [weak self] in
                let t = self?.chipTemp.read()
                DispatchQueue.main.async { guard let self else { return }; if self.chipC != t { self.chipC = t }; self.tempBusy = false }
            }
        }
        let now = Date(); let dt = max(now.timeIntervalSince(lastIOTime), 0.1); lastIOTime = now
        sampleDisks(dt); sampleNet(dt)
    }

    static func push(_ arr: [Double]?, _ v: Double) -> [Double] {
        var a = arr ?? Array(repeating: 0, count: historyLen)
        a.removeFirst(); a.append(v); return a
    }

    private func sampleMemory() {
        var st = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &st) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size) / 1_073_741_824
        memApp = Double(st.internal_page_count &- st.purgeable_count) * page
        memWired = Double(st.wire_count) * page
        memCompressed = Double(st.compressor_page_count) * page
        memCached = Double(st.external_page_count &+ st.purgeable_count) * page
        memFree = Double(st.free_count) * page
        var sw = xsw_usage(); var sz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &sz, nil, 0) == 0 { swapUsed = Double(sw.xsu_used) / 1_073_741_824 }
        let used = memApp + memWired + memCompressed
        let gpu = min(gpuMemGB, used)
        memGPU.removeFirst(); memGPU.append(gpu)
        memCPU.removeFirst(); memCPU.append(max(used - gpu, 0))
    }

    private func sampleDisks(_ dt: Double) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        var seen: [String: (UInt64, UInt64)] = [:]
        var order: [String] = []
        while case let drv = IOIteratorNext(iter), drv != 0 {
            defer { IOObjectRelease(drv) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(drv, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let d = props?.takeRetainedValue() as? [String: Any],
                  let st = d["Statistics"] as? [String: Any] else { continue }
            let r = (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let w = (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            // name from the child IOMedia (whole disk)
            var name = "Disk"
            var child: io_registry_entry_t = 0
            if IORegistryEntryGetChildEntry(drv, kIOServicePlane, &child) == KERN_SUCCESS {
                var buf = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(child, &buf)
                let bsd = IORegistryEntryCreateCFProperty(child, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? ""
                name = String(cString: buf).replacingOccurrences(of: " Media", with: "") + (bsd.isEmpty ? "" : " (\(bsd))")
                IOObjectRelease(child)
            }
            if seen[name] != nil { name += " #\(order.count)" }
            seen[name] = (r, w); order.append(name)
        }
        var out: [(name: String, read: [Double], write: [Double])] = []
        for n in order {
            let (r, w) = seen[n]!
            let old = disks.first { $0.name == n }
            var rr = 0.0, ww = 0.0
            if let p = prevDisk[n] { rr = Double(r &- p.0) / dt; ww = Double(w &- p.1) / dt
                if r < p.0 { rr = 0 }; if w < p.1 { ww = 0 } }
            out.append((n, Self.push(old?.read, rr), Self.push(old?.write, ww)))
        }
        prevDisk = seen; disks = out
    }

    private func sampleNet(_ dt: Double) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return }
        defer { freeifaddrs(ifap) }
        let skip = ["lo", "gif", "stf", "anpi", "ap", "awdl", "llw", "bridge"]
        var seen: [String: (UInt64, UInt64)] = [:]; var order: [String] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
                  (ifa.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if skip.contains(where: { name.hasPrefix($0) }) { continue }
            let i = UInt64(data.pointee.ifi_ibytes), o = UInt64(data.pointee.ifi_obytes)
            if i == 0 && o == 0 { continue }
            // macOS keeps several idle utun tunnels (iCloud Private Relay, Continuity, VPN clients);
            // hide them unless they've actually carried traffic.
            if name.hasPrefix("utun") && i + o < 1_000_000 { continue }
            seen[name] = (i, o); order.append(name)
        }
        var out: [(name: String, label: String, down: [Double], up: [Double])] = []
        for n in order {
            let (i, o) = seen[n]!
            let old = nets.first { $0.name == n }
            var di = 0.0, uo = 0.0
            if let pr = prevNet[n] {
                // counters are 32-bit and wrap; &- on UInt32 handles it
                di = Double(UInt32(truncatingIfNeeded: i) &- UInt32(truncatingIfNeeded: pr.0)) / dt
                uo = Double(UInt32(truncatingIfNeeded: o) &- UInt32(truncatingIfNeeded: pr.1)) / dt
            }
            out.append((n, netNames.label(n), Self.push(old?.down, di), Self.push(old?.up, uo)))
        }
        prevNet = seen; nets = out
    }

    private func sampleCPU() {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        let n = Int(count)
        var ticks: [[UInt32]] = []
        for i in 0..<n {
            let b = Int(CPU_STATE_MAX) * i
            ticks.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[b + $0]) })
        }
        if cpu.count != n { cpu = Array(repeating: Array(repeating: 0, count: Self.historyLen), count: n) }
        if prevTicks.count == n {
            var sys = 0.0, usr = 0.0, all = 0.0
            for i in 0..<n {
                for k in 0..<ticks[i].count {
                    let d = Double(ticks[i][k] &- prevTicks[i][k]); all += d
                    if k == Int(CPU_STATE_SYSTEM) { sys += d } else if k == Int(CPU_STATE_USER) || k == Int(CPU_STATE_NICE) { usr += d }
                }
            }
            if all > 0 { cpuSys = Self.push(cpuSys, sys / all); cpuUser = Self.push(cpuUser, usr / all) }
            for i in 0..<n {
                let d = (0..<ticks[i].count).map { Double(ticks[i][$0] &- prevTicks[i][$0]) }
                let total = d.reduce(0, +)
                let idle = d[Int(CPU_STATE_IDLE)]
                let load = total > 0 ? (total - idle) / total : 0
                cpu[i].removeFirst(); cpu[i].append(load)
            }
        }
        prevTicks = ticks
    }

    private func sampleGPU() {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        let svc = IOIteratorNext(iter); guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return }
        gpuCores = dict["gpu-core-count"] as? Int ?? 0
        if let stats = dict["PerformanceStatistics"] as? [String: Any] {
            for k in gpuKeys {
                let v = Double((stats[k] as? Int) ?? 0) / 100
                gpu[k]?.removeFirst(); gpu[k]?.append(v)
            }
            gpuMemGB = Double((stats["In use system memory"] as? Int) ?? 0) / 1_073_741_824
            gpuMemHist.removeFirst(); gpuMemHist.append(min(gpuMemGB / max(totalMemGB, 1), 1))
        }
    }
}

// MARK: - Views
/// One layer of a chart: optional fill between `base` (or the floor) and `data`, plus an optional line on top.
struct ChartLayer {
    var data: [Double]
    var base: [Double]? = nil
    var color: Color
    var fill: Double? = 0.35      // fill opacity, nil = no fill
    var line = true
}

/// All graphs draw through this single Canvas: one layer per card instead of a stack of SwiftUI Paths,
/// so the 1 s updates are much cheaper to diff and render.
struct ChartCanvas: View {
    let layers: [ChartLayer]
    var maxValue: Double = 1
    var grid = true
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let n = layers.first?.data.count ?? 1, step = w / CGFloat(max(n - 1, 1))
            let peak = max(maxValue, 1e-9)
            func pt(_ i: Int, _ v: Double) -> CGPoint { CGPoint(x: CGFloat(i) * step, y: h * (1 - CGFloat(min(max(v / peak, 0), 1)))) }
            let clip = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
            ctx.fill(clip, with: .color(.black.opacity(0.85)))
            ctx.clip(to: clip)
            if grid {
                var gp = Path()
                for f in stride(from: 0.25, to: 1.0, by: 0.25) { gp.move(to: CGPoint(x: 0, y: h * f)); gp.addLine(to: CGPoint(x: w, y: h * f)) }
                ctx.stroke(gp, with: .color(.white.opacity(0.1)), lineWidth: 0.5)
            }
            for l in layers where !l.data.isEmpty {
                var line = Path()
                for (i, v) in l.data.enumerated() { i == 0 ? line.move(to: pt(i, v)) : line.addLine(to: pt(i, v)) }
                if let op = l.fill {
                    var area = line
                    if let b = l.base { for i in b.indices.reversed() { area.addLine(to: pt(i, b[i])) } }
                    else { area.addLine(to: CGPoint(x: w, y: h)); area.addLine(to: CGPoint(x: 0, y: h)) }
                    area.closeSubpath()
                    ctx.fill(area, with: .color(l.color.opacity(op)))
                }
                if l.line { ctx.stroke(line, with: .color(l.color), lineWidth: 1.5) }
            }
        }
    }
}

struct Graph: View {
    let title: String
    let data: [Double]
    let color: Color
    var valueText: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                Text(valueText ?? "\(Int((data.last ?? 0) * 100))%").font(.caption.monospacedDigit())
            }
            ChartCanvas(layers: [ChartLayer(data: data, color: color)])
            .frame(height: 80)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)))
    }
}

struct StackedGraph: View {
    let title: String
    let bottom: [Double]; let top: [Double]   // stacked: bottom first, top on top
    let total: Double
    let bottomLabel: String; let topLabel: String
    let bottomColor: Color; let topColor: Color
    var height: CGFloat = 160
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                Text("\(topLabel) \(String(format: "%.1f", top.last ?? 0)) GB").foregroundStyle(topColor)
                Text("\(bottomLabel) \(String(format: "%.1f", bottom.last ?? 0)) GB").foregroundStyle(bottomColor)
            }.font(.caption.monospacedDigit())
            ChartCanvas(layers: [
                // same look as the combined CPU graph: 35% bands with a solid line on each layer
                ChartLayer(data: bottom, color: bottomColor),
                ChartLayer(data: zip(bottom, top).map { $0 + $1 }, base: bottom, color: topColor)],
                maxValue: max(total, 0.001))
            .frame(height: height)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)))
    }
}

func fmtRate(_ b: Double) -> String {
    let u = ["B/s", "KB/s", "MB/s", "GB/s"]; var v = b; var i = 0
    while v >= 1000 && i < u.count - 1 { v /= 1000; i += 1 }
    return String(format: i == 0 ? "%.0f %@" : "%.1f %@", v, u[i])
}

struct RateGraph: View {
    let title: String
    let a: [Double]; let b: [Double]
    let aLabel: String; let bLabel: String
    let aColor: Color; let bColor: Color
    var body: some View {
        let peak = max((a + b).max() ?? 0, 1024)
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).lineLimit(1)
            HStack(spacing: 8) {
                Text("\(aLabel) \(fmtRate(a.last ?? 0))").foregroundStyle(aColor)
                Text("\(bLabel) \(fmtRate(b.last ?? 0))").foregroundStyle(bColor)
            }.font(.caption2.monospacedDigit())
            ZStack(alignment: .topTrailing) {
                ChartCanvas(layers: [ChartLayer(data: a, color: aColor, fill: nil), ChartLayer(data: b, color: bColor, fill: nil)], maxValue: peak, grid: false)
                Text("peak \(fmtRate(peak))").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).padding(3)
            }
            .frame(height: 80)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)))
    }
}

/// Live reordering: as the dragged row passes over another row, the list shifts immediately.
struct SidebarDrop: DropDelegate {
    let target: String
    let ui: GraphUI
    func dropEntered(info: DropInfo) {
        guard let d = ui.dragging, d != target else { return }
        withAnimation(.snappy(duration: 0.2)) { ui.move(d, before: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { withAnimation { ui.dragging = nil; ui.objectWillChange.send() }; return true }
}

final class GraphUI: ObservableObject {
    @Published var selected: [String] = ["CPU"]   // shown top-to-bottom in sidebar order
    var anchor = "CPU"                             // for shift-click ranges
    var dragging: String?                          // sidebar item currently being dragged
    /// Starts a drag and clears it once the mouse is released anywhere (even outside the sidebar).
    func beginDrag(_ name: String) {
        dragging = name
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.dragging != nil else { return }
                if NSEvent.pressedMouseButtons == 0 { withAnimation { self.dragging = nil; self.objectWillChange.send() } } else { poll() }
            }
        }
        poll()
    }
    static let all = ["CPU", "GPU", "Memory", "Drives", "Network"]
    /// Sidebar order, rearranged by dragging and remembered across launches.
    @Published var order: [String] = {
        let saved = UserDefaults.standard.stringArray(forKey: "sidebarOrder") ?? []
        return saved.filter(GraphUI.all.contains) + GraphUI.all.filter { !saved.contains($0) }
    }() { didSet { UserDefaults.standard.set(order, forKey: "sidebarOrder"); selected = order.filter(selected.contains) } }
    func move(_ item: String, before target: String) {
        guard item != target, var o = Optional(order), let from = o.firstIndex(of: item) else { return }
        o.remove(at: from)
        o.insert(item, at: o.firstIndex(of: target).map { from <= $0 ? $0 + 1 : $0 } ?? o.count)
        order = o
    }
}

struct ContentView: View {
    @ObservedObject var feed: Feed
    var m: Monitor { feed.m }
    @StateObject var ui = GraphUI()
    let cols = [GridItem(.adaptive(minimum: 160), spacing: 10)]
    let icons = ["CPU": "cpu", "GPU": "display", "Memory": "memorychip", "Drives": "internaldrive", "Network": "network"]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ui.order, id: \.self) { name in
                    Button { click(name) } label: {
                        Label(name, systemImage: icons[name]!).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(ui.selected.contains(name) ? Color.accentColor.opacity(0.25) : .clear))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .opacity(ui.dragging == name ? 0 : 1)   // leave a gap; the cursor shows the dragged copy
                    .onDrag { ui.beginDrag(name); return NSItemProvider(object: name as NSString) }
                    .onDrop(of: [.text], delegate: SidebarDrop(target: name, ui: ui))
                }
                // "All": selects every section; highlighted whenever everything is selected. Not draggable.
                let allOn = ui.selected.count == ui.order.count
                Button { ui.selected = ui.order; ui.anchor = ui.order.first ?? "CPU" } label: {
                    Label("All", systemImage: "square.grid.2x2").frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(allOn ? Color.accentColor.opacity(0.25) : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Spacer()
            }.frame(width: 130).padding(.top, 12).padding(.horizontal, 6)
            .background(Color.gray.opacity(0.08))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(ui.selected, id: \.self) { sec in
                        switch sec {
                        case "GPU": gpuSection
                        case "Memory": memSection
                        case "Drives": drivesSection
                        case "Network": netSection
                        default: cpuSection
                        }
                        if sec != ui.selected.last { Divider() }
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }.frame(minWidth: 560, minHeight: 640)
    }

    /// Click = only this; ⌘/⌃-click = toggle; ⇧-click = range from the last clicked item.
    func click(_ name: String) {
        let flags = NSEvent.modifierFlags, order = ui.order
        var sel = Set(ui.selected)
        if flags.contains(.shift), let a = order.firstIndex(of: ui.anchor), let b = order.firstIndex(of: name) {
            sel.formUnion(order[min(a, b)...max(a, b)])
        } else if flags.contains(.command) || flags.contains(.control) {
            if sel.contains(name) { if sel.count > 1 { sel.remove(name) } } else { sel.insert(name) }
            ui.anchor = name
        } else { sel = [name]; ui.anchor = name }
        ui.selected = order.filter(sel.contains)
    }

    var cpuSection: some View {
        let avg = m.cpu.isEmpty ? 0 : m.cpu.map { $0.last ?? 0 }.reduce(0, +) / Double(m.cpu.count)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("CPU").font(.title2.bold())
                Text("\(m.cpu.count) cores · \(m.pCores)P + \(m.eCores)E · avg \(Int(avg * 100))%" + (m.chipC.map { " · chip \(Int($0.rounded()))°C" } ?? "")).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(get: { m.cpuCombined }, set: { m.cpuCombined = $0 })) { Text("Per Core").tag(false); Text("Combined").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            }
            if m.cpuCombined {
                // Whole chip: system (red) stacked under user (blue), like Activity Monitor's CPU Load.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("All cores").font(.caption.bold()); Spacer()
                        Text("System \(Int(((m.cpuSys.last ?? 0) * 100).rounded()))%").foregroundStyle(.red)
                        Text("User \(Int(((m.cpuUser.last ?? 0) * 100).rounded()))%").foregroundStyle(.blue)
                    }.font(.caption.monospacedDigit())
                    MiniChart(series: [(m.cpuSys, .red), (m.cpuUser, .blue)], stacked: true, maxValue: 1).frame(height: 120)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)))
            } else {
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(m.cpu.indices, id: \.self) { i in
                        let isE = i < m.eCores
                        Graph(title: "Core \(i) \(isE ? "(E)" : "(P)")", data: m.cpu[i], color: isE ? .green : .orange)
                    }
                }
            }
        }
    }

    var gpuSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("GPU").font(.title2.bold())
                Text("\(m.gpuCores) cores · \(Int(m.totalMemGB.rounded())) GB").foregroundStyle(.secondary)
            }
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(m.gpuKeys, id: \.self) { k in
                    Graph(title: k.replacingOccurrences(of: " Utilization %", with: ""), data: m.gpu[k] ?? [], color: .cyan)
                }
                Graph(title: "Memory", data: m.gpuMemHist, color: .purple,
                      valueText: String(format: "%.2f GB", m.gpuMemGB))
            }
            Text("macOS only reports GPU load for the whole GPU, not per GPU core.").font(.caption).foregroundStyle(.secondary)
        }
    }

    var memSection: some View {
        let used = m.memApp + m.memWired + m.memCompressed
        let gb = { (v: Double) in String(format: "%.1f GB", v) }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Memory").font(.title2.bold())
                Text("\(Int(m.totalMemGB.rounded())) GB · \(gb(used)) used").foregroundStyle(.secondary)
            }
            StackedGraph(title: "Used", bottom: m.memCPU, top: m.memGPU, total: m.totalMemGB,
                         bottomLabel: "CPU", topLabel: "GPU", bottomColor: .orange, topColor: .cyan, height: 200)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow { Text("App memory"); Text(gb(m.memApp)).monospacedDigit() }
                GridRow { Text("Wired"); Text(gb(m.memWired)).monospacedDigit() }
                GridRow { Text("Compressed"); Text(gb(m.memCompressed)).monospacedDigit() }
                GridRow { Text("Cached files"); Text(gb(m.memCached)).monospacedDigit() }
                GridRow { Text("Free"); Text(gb(m.memFree)).monospacedDigit() }
                GridRow { Text("Swap used"); Text(gb(m.swapUsed)).monospacedDigit() }
            }.font(.callout)
            Text("Memory is shared between CPU and GPU. GPU = memory the GPU driver has in use; CPU = everything else that's used (app, wired, compressed).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    var drivesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Drives").font(.title2.bold())
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(m.disks, id: \.name) { d in
                    RateGraph(title: d.name, a: d.read, b: d.write, aLabel: "R", bLabel: "W", aColor: .blue, bColor: .pink)
                }
            }
        }
    }

    var netSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Network").font(.title2.bold())
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(m.nets, id: \.name) { n in
                    RateGraph(title: n.label, a: n.down, b: n.up, aLabel: "↓", bLabel: "↑", aColor: .mint, bColor: .yellow)
                }
            }
        }
    }
}

@main
struct CoreMonitorApp: App {
    var body: some Scene {
        WindowGroup("Core Monitor") { RootView() }
    }
}
