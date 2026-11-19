import SwiftUI
import Combine
import Darwin
import IOKit
import CoreWLAN

struct ProcRow: Identifiable {
    let id: Int32          // pid
    var name = "", user = ""
    var cpu = 0.0          // % of one core
    var cpuTime = 0.0      // seconds
    var threads = 0
    var wakeups = 0.0      // idle wake-ups / sec
    var gpu = 0.0          // % of GPU time
    var mem = 0.0          // bytes (physical footprint)
    var power = 0.0        // watts (from the kernel's per-process energy counter)
    var diskRead = 0.0, diskWrite = 0.0                 // bytes/sec
    var diskReadTotal = 0.0, diskWriteTotal = 0.0       // bytes since launch
    var netIn = 0.0, netOut = 0.0                       // bytes/sec
    var netInTotal = 0.0, netOutTotal = 0.0             // bytes seen by nettop
    var ifTotal: [String: (Double, Double)] = [:]       // network group -> (rcvd, sent) bytes seen by Core Monitor
    var ifRate: [String: (Double, Double)] = [:]        // network group -> (rcvd, sent) bytes/sec
    var icon: NSImage? = nil
}

final class ProcMonitor: ObservableObject {
    @Published var rows: [ProcRow] = []
    @Published var unreadable = 0
    @Published var threadCount = 0
    @Published var powerHist: [Double] = Array(repeating: 0, count: Monitor.historyLen)
    /// Sampling only runs while the Processes tab is visible.
    var active = false { didSet { if active && !oldValue { kick(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.kick() } } } }
    var visible = false
    /// Sampling resumes ~0.4 s after the page is shown, so it never lands mid-animation.
    func setVisible(_ v: Bool) {
        visible = v
        if v { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if self.visible { self.active = true } } } else { active = false }
    }
    private struct Prev { var cpuNs: UInt64; var wk: UInt64; var nj: UInt64 }
    private var prev: [Int32: Prev] = [:]
    private var prevGPU: [Int32: UInt64] = [:]
    private var prevNet: [Int32: (UInt64, UInt64)] = [:]
    @Published var netGroups: [String] = []
    private var userNames: [uid_t: String] = [:]
    private var lastTime = Date()
    private var timer: Timer?
    private var busy = false   // main-thread only: skip a tick rather than queue up behind a slow sample
    private let q = DispatchQueue(label: "procmon", qos: .utility)
    private let tb: Double = { var t = mach_timebase_info(); mach_timebase_info(&t); return Double(t.numer) / Double(t.denom) }()

    init() {
        startNettop()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in if self?.active == true { self?.kick() } }
        timer?.tolerance = 0.5
        kick()   // prewarm: rows + icons are ready before the tab is first opened
    }
    private func kick() {
        guard !busy else { return }; busy = true
        q.async { self.sample() }
    }

    private func gpuTimes() -> [Int32: UInt64] {
        var out: [Int32: UInt64] = [:]
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXDeviceUserClient"), &iter) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(iter) }
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            guard let creator = IORegistryEntryCreateCFProperty(s, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  creator.hasPrefix("pid "),
                  let pid = Int32(creator.dropFirst(4).prefix { $0.isNumber }) else { continue }
            if let usage = IORegistryEntryCreateCFProperty(s, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] {
                for u in usage { out[pid, default: 0] += (u["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0 }
            }
        }
        return out
    }

    // One long-lived `nettop` streaming a snapshot every 2s, instead of launching nettop (which blocks
    // ~5s) on every sample. Output blocks start with a ",bytes_in,bytes_out," header, then "name.pid,in,out,".
    private let netLock = NSLock()
    /// Latest nettop snapshot: per-process lifetime totals, plus each open connection's bytes and interface.
    struct NetSnap { var procs: [Int32: (UInt64, UInt64)] = [:]; var conns: [String: (pid: Int32, iface: String, i: UInt64, o: UInt64)] = [:] }
    private var netLatest = NetSnap()
    /// Network data comes only from one-shot `nettop -L 1` snapshots: any continuously streaming nettop
    /// (`-L 0`) burns ~140% CPU, while one snapshot costs ~0.09 s of CPU (and ~5 s of wall time).
    private func startNettop() { startConnPoller() }

    /// Snapshots run back to back while the Processes page is visible (~5 s apart), and every
    /// 15 s otherwise so the per-network totals keep accumulating.
    private var connPollerStarted = false
    private func startConnPoller() {
        guard !connPollerStarted else { return }; connPollerStarted = true
        Thread.detachNewThread { [weak self] in
            while self != nil {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
                p.arguments = ["-L", "1", "-x", "-J", "interface,bytes_in,bytes_out"]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
                if (try? p.run()) != nil {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                    var conns: [String: (pid: Int32, iface: String, i: UInt64, o: UInt64)] = [:], pid: Int32 = -1
                    var procs: [Int32: (UInt64, UInt64)] = [:]
                    for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
                        // columns: name, interface, bytes_in, bytes_out; process rows have an empty interface
                        let f = line.split(separator: ",", omittingEmptySubsequences: false)
                        guard f.count >= 4 else { continue }
                        if f[1].isEmpty, let dot = f[0].lastIndex(of: "."), let p = Int32(f[0][f[0].index(after: dot)...]) {
                            pid = p; procs[p] = (UInt64(f[2]) ?? 0, UInt64(f[3]) ?? 0)
                        }
                        else if !f[1].isEmpty, pid >= 0 {
                            conns["\(pid)|\(f[0])|\(f[1])"] = (pid, String(f[1]), UInt64(f[2]) ?? 0, UInt64(f[3]) ?? 0)
                        }
                    }
                    if let self { self.netLock.lock(); self.netLatest = NetSnap(procs: procs, conns: conns); self.netLock.unlock() }
                }
                Thread.sleep(forTimeInterval: self?.visible == true ? 0.5 : 15)
            }
        }
    }
    private func netSnap() -> NetSnap { netLock.lock(); defer { netLock.unlock() }; return netLatest }

    /// Interface → network group shown as a column ("Wi-Fi", "Ethernet", "VPN / Tunnel"). Loopback is local, so skipped.
    private func group(_ iface: String) -> String? {
        if iface.hasPrefix("lo") { return nil }
        if iface.hasPrefix("utun") || iface.hasPrefix("ipsec") { return "VPN / Tunnel" }
        if let g = groupNames[iface] { return g }
        let g: String
        if CWWiFiClient.shared().interface(withName: iface) != nil { g = "Wi-Fi" }
        else if iface.hasPrefix("en") { g = "Ethernet (\(iface))" }
        else { g = iface }
        groupNames[iface] = g; return g
    }
    private var groupNames: [String: String] = [:]
    private var icons: [Int32: NSImage?] = [:]
    /// App icon for a process, like Activity Monitor: the app's own icon, helpers inside an .app get
    /// the outer app's icon, and plain daemons/CLI tools get none. Looked up on the sampler's
    /// background queue (never on the main thread, which made tab switches stutter) and cached per pid.
    func icon(_ pid: Int32) -> NSImage? {
        if let c = icons[pid] { return c }
        var img: NSImage? = NSRunningApplication(processIdentifier: pid)?.icon
        if img == nil {
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
                let path = String(cString: buf)
                if let r = path.range(of: ".app/") { img = NSWorkspace.shared.icon(forFile: String(path[..<r.lowerBound]) + ".app") }
            }
        }
        img?.size = NSSize(width: 16, height: 16)
        icons[pid] = img; return img
    }

    /// Per-process, per-network byte totals that Core Monitor accumulates itself (connections vanish from nettop when closed).
    private var ifaceTotals: [Int32: [String: (Double, Double)]] = [:]
    private var prevConns: [String: (UInt64, UInt64)] = [:]

    private func userName(_ uid: uid_t) -> String {
        if let n = userNames[uid] { return n }
        let n = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "\(uid)"
        userNames[uid] = n; return n
    }

    private func sample() {
        let now = Date(); let dt = max(now.timeIntervalSince(lastTime), 0.25); lastTime = now
        let n = proc_listallpids(nil, 0)
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        let gpu = gpuTimes(), snap = netSnap(), net = snap.procs
        var ifRate: [Int32: [String: (Double, Double)]] = [:]
        for (key, c) in snap.conns {
            guard let g = group(c.iface) else { continue }
            let p = prevConns[key]
            // new connection: count all its bytes; existing: count the growth since last sample
            let di = Double(p.map { c.i >= $0.0 ? c.i - $0.0 : 0 } ?? c.i), d_o = Double(p.map { c.o >= $0.1 ? c.o - $0.1 : 0 } ?? c.o)
            let t = ifaceTotals[c.pid]?[g] ?? (0, 0)
            ifaceTotals[c.pid, default: [:]][g] = (t.0 + di, t.1 + d_o)
            if p != nil { let r = ifRate[c.pid]?[g] ?? (0, 0); ifRate[c.pid, default: [:]][g] = (r.0 + di / dt, r.1 + d_o / dt) }
        }
        prevConns = snap.conns.mapValues { ($0.i, $0.o) }
        let groups = Set(ifaceTotals.values.flatMap { $0.keys }).sorted { ($0 == "Wi-Fi" ? "0" : $0) < ($1 == "Wi-Fi" ? "0" : $1) }
        var rows: [ProcRow] = []; rows.reserveCapacity(got)
        var bad = 0, threads = 0, watts = 0.0
        var newPrev: [Int32: Prev] = [:]
        var nameBuf = [CChar](repeating: 0, count: 256)
        let pidSet = Set(pids.prefix(got))
        for pid in pids.prefix(got) where pid > 0 {
            proc_name(pid, &nameBuf, 256)
            var row = ProcRow(id: pid)
            row.name = String(cString: nameBuf); if row.name.isEmpty { row.name = "pid \(pid)" }
            var sbi = proc_bsdshortinfo()
            if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &sbi, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0 { row.user = userName(sbi.pbsi_uid) }
            var ti = proc_taskinfo()
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 { row.threads = Int(ti.pti_threadnum); threads += row.threads }
            var ru = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            } == 0
            if ok {
                let cur = Prev(cpuNs: UInt64(Double(ru.ri_user_time + ru.ri_system_time) * tb),
                               wk: ru.ri_pkg_idle_wkups + ru.ri_interrupt_wkups, nj: ru.ri_energy_nj)
                row.cpuTime = Double(cur.cpuNs) / 1e9
                row.mem = Double(ru.ri_phys_footprint)
                row.diskReadTotal = Double(ru.ri_diskio_bytesread); row.diskWriteTotal = Double(ru.ri_diskio_byteswritten)
                if let p = prev[pid] {
                    row.cpu = Double(cur.cpuNs &- p.cpuNs) / (dt * 1e9) * 100
                    row.wakeups = Double(cur.wk &- p.wk) / dt
                    row.power = cur.nj >= p.nj ? Double(cur.nj - p.nj) / 1e9 / dt : 0
                    watts += row.power
                }
                newPrev[pid] = cur
            } else { bad += 1 }
            if let g = gpu[pid], let pg = prevGPU[pid], g >= pg { row.gpu = Double(g - pg) / (dt * 1e9) * 100 }
            if let c = net[pid] {
                row.netInTotal = Double(c.0); row.netOutTotal = Double(c.1)
                if let pn = prevNet[pid] {
                    row.netIn = c.0 >= pn.0 ? Double(c.0 - pn.0) / dt : 0
                    row.netOut = c.1 >= pn.1 ? Double(c.1 - pn.1) / dt : 0
                }
            }
            row.icon = icon(pid)
            if let t = ifaceTotals[pid] { row.ifTotal = t }
            if let r = ifRate[pid] { row.ifRate = r }
            rows.append(row)
        }
        ifaceTotals = ifaceTotals.filter { pidSet.contains($0.key) }   // drop exited processes
        if icons.count > pidSet.count + 50 { icons = icons.filter { pidSet.contains($0.key) } }   // pids get reused
        // Rate fields need two samples; DiskRead/Write deltas come from the same counters.
        for i in rows.indices { if let p = prevDisk[rows[i].id] {
            rows[i].diskRead = max(rows[i].diskReadTotal - p.0, 0) / dt; rows[i].diskWrite = max(rows[i].diskWriteTotal - p.1, 0) / dt } }
        prevDisk = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, ($0.diskReadTotal, $0.diskWriteTotal)) })
        let hadPrev = !prev.isEmpty
        prev = newPrev; prevGPU = gpu; prevNet = net
        DispatchQueue.main.async {
            self.rows = rows; self.unreadable = bad; if self.netGroups != groups { self.netGroups = groups }; self.threadCount = threads
            if hadPrev { self.powerHist = Monitor.push(self.powerHist, watts) }
            self.busy = false
        }
    }
    private var prevDisk: [Int32: (Double, Double)] = [:]
}

func fmtBytes(_ b: Double) -> String {
    let u = ["bytes", "KB", "MB", "GB", "TB"]; var v = b; var i = 0
    while v >= 1000 && i < u.count - 1 { v /= 1000; i += 1 }
    return String(format: i == 0 ? "%.0f %@" : "%.1f %@", v, u[i])
}
func fmtTime(_ s: Double) -> String {
    let h = Int(s) / 3600, m = Int(s) / 60 % 60, sec = s.truncatingRemainder(dividingBy: 60)
    return h > 0 ? String(format: "%d:%02d:%05.2f", h, m, sec) : String(format: "%d:%05.2f", m, sec)
}

enum ProcTab: String, CaseIterable { case cpu = "CPU", memory = "Memory", energy = "Energy", disk = "Disk", network = "Network" }

final class ProcUI: ObservableObject {
    @Published var tab = ProcTab.cpu
    @Published var filter = ""
}

private func num(_ v: Double, _ f: String = "%.1f") -> some View { Text(String(format: f, v)).monospacedDigit() }
private func txt(_ s: String) -> some View { Text(s).monospacedDigit().lineLimit(1) }

struct ProcessesView: View {
    let feed: Feed   // not observed here: only ProcSummary redraws on the 1s graph tick, not the big table
    @ObservedObject var pm: ProcMonitor
    @StateObject var ui = ProcUI()

    var filtered: [ProcRow] { ui.filter.isEmpty ? pm.rows : pm.rows.filter { $0.name.localizedCaseInsensitiveContains(ui.filter) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $ui.tab.deferred) { ForEach(ProcTab.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                Spacer()
                TextField("Search", text: $ui.filter).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            if pm.rows.isEmpty { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) } else { table }
            ProcSummary(feed: feed, pm: pm, tab: ui.tab).frame(height: 200)
        }.padding()

    }

    var table: some View { ProcTable(rows: filtered, tab: ui.tab, groups: ui.tab == .network ? pm.netGroups : []) }
}

/// Column definition for the AppKit process table.
struct ProcCol {
    let id: String, title: String, width: CGFloat, numeric: Bool
    let text: (ProcRow) -> String
    let less: (ProcRow, ProcRow) -> Bool
    init<V: Comparable>(_ id: String, _ title: String, _ width: CGFloat, numeric: Bool = true, _ key: KeyPath<ProcRow, V>, _ text: @escaping (ProcRow) -> String) {
        self.id = id; self.title = title; self.width = width; self.numeric = numeric; self.text = text
        self.less = { $0[keyPath: key] < $1[keyPath: key] }
    }
    init(_ id: String, _ title: String, _ width: CGFloat, value: @escaping (ProcRow) -> Double, _ text: @escaping (Double) -> String) {
        self.id = id; self.title = title; self.width = width; self.numeric = true
        self.text = { text(value($0)) }; self.less = { value($0) < value($1) }
    }
    static let name = ProcCol("name", "Process Name", 240, numeric: false, \.name) { $0.name }
    static let pid = ProcCol("pid", "PID", 60, \.id) { "\($0.id)" }
    static let user = ProcCol("user", "User", 100, numeric: false, \.user) { $0.user }
    static let cpu = ProcCol("cpu", "% CPU", 65, \.cpu) { String(format: "%.1f", $0.cpu) }
    static let threads = ProcCol("threads", "Threads", 65, \.threads) { "\($0.threads)" }
    static let wake = ProcCol("wake", "Idle Wake Ups", 100, \.wakeups) { String(format: "%.0f", $0.wakeups) }
    static func columns(_ t: ProcTab, groups: [String] = []) -> [ProcCol] {
        switch t {
        case .cpu: return [name, cpu, ProcCol("cputime", "CPU Time", 90, \.cpuTime) { fmtTime($0.cpuTime) }, threads, wake,
                           ProcCol("gpu", "% GPU", 65, \.gpu) { String(format: "%.1f", $0.gpu) }, pid, user]
        case .memory: return [name, ProcCol("mem", "Memory", 100, \.mem) { fmtBytes($0.mem) }, threads, pid, user]
        case .energy: return [name, ProcCol("power", "Power (W)", 90, \.power) { String(format: "%.2f", $0.power) }, cpu, wake, pid, user]
        case .disk: return [name, ProcCol("bw", "Bytes Written", 105, \.diskWriteTotal) { fmtBytes($0.diskWriteTotal) },
                            ProcCol("br", "Bytes Read", 105, \.diskReadTotal) { fmtBytes($0.diskReadTotal) },
                            ProcCol("ws", "Write/s", 90, \.diskWrite) { fmtRate($0.diskWrite) },
                            ProcCol("rs", "Read/s", 90, \.diskRead) { fmtRate($0.diskRead) }, pid, user]
        case .network: return [name, ProcCol("sent", "Sent Bytes", 105, \.netOutTotal) { fmtBytes($0.netOutTotal) },
                               ProcCol("rcvd", "Rcvd Bytes", 105, \.netInTotal) { fmtBytes($0.netInTotal) },
                               ProcCol("sps", "Sent/s", 90, \.netOut) { fmtRate($0.netOut) },
                               ProcCol("rps", "Rcvd/s", 90, \.netIn) { fmtRate($0.netIn) }]
            + groups.flatMap { g in [
                ProcCol("s:\(g)", "\(g) Sent", 120, value: { $0.ifTotal[g]?.1 ?? 0 }, fmtBytes),
                ProcCol("r:\(g)", "\(g) Rcvd", 120, value: { $0.ifTotal[g]?.0 ?? 0 }, fmtBytes)] }
            + [pid, user]
        }
    }
    static let defaultSort: [ProcTab: String] = [.cpu: "cpu", .memory: "mem", .energy: "power", .disk: "bw", .network: "sent"]
}

/// Table cell that draws its own icon + text: no NSTextField, no Auto Layout. Refreshing ~40 visible rows
/// of NSTextFields with constraints every 2 s was the bulk of the Processes page's CPU use.
final class TextCell: NSView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var icon: NSImage? { didSet { if icon !== oldValue { needsDisplay = true } } }
    var hasIconSlot = false
    var alignment: NSTextAlignment = .left
    static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirty: NSRect) {
        var x: CGFloat = 2
        if hasIconSlot {
            icon?.draw(in: NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16))
            x += 22
        }
        let para = NSMutableParagraphStyle(); para.alignment = alignment; para.lineBreakMode = .byTruncatingTail
        let selected = (superview as? NSTableRowView)?.isSelected == true && (superview as? NSTableRowView)?.isEmphasized == true
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .paragraphStyle: para,
                                                    .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor]
        let h = Self.font.ascender - Self.font.descender
        (text as NSString).draw(with: NSRect(x: x, y: (bounds.height - h) / 2, width: bounds.width - x - 2, height: h + 2),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }
}

/// NSTableView-backed table (like Activity Monitor): reuses cells, so tab switches and 2s refreshes are cheap.
struct ProcTable: NSViewRepresentable {
    let rows: [ProcRow]
    let tab: ProcTab
    var groups: [String] = []

    func makeCoordinator() -> Coord { Coord() }
    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTableView()
        tv.usesAlternatingRowBackgroundColors = true
        tv.allowsColumnReordering = true; tv.allowsMultipleSelection = false
        tv.style = .inset; tv.rowHeight = 18
        tv.dataSource = context.coordinator; tv.delegate = context.coordinator
        context.coordinator.tv = tv
        let sv = NSScrollView(); sv.documentView = tv; sv.hasVerticalScroller = true; sv.autohidesScrollers = true
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) { context.coordinator.update(rows: rows, tab: tab, groups: groups) }

    final class Coord: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tv: NSTableView?
        var tab: ProcTab?
        var cols: [String: ProcCol] = [:]
        var sorted: [ProcRow] = []
        var raw: [ProcRow] = []
        var sortState: [ProcTab: (String, Bool)] = [:]   // per-tab column id + ascending
    
        var groups: [String] = []
        var needsReload = true
        func update(rows: [ProcRow], tab: ProcTab, groups: [String]) {
            guard let tv else { return }
            raw = rows
            if tab != self.tab || groups != self.groups {
                let tabChanged = tab != self.tab
                needsReload = true
                self.tab = tab; self.groups = groups
                let widths = Dictionary(tv.tableColumns.map { ($0.identifier.rawValue, $0.width) }, uniquingKeysWith: { a, _ in a })
                for c in tv.tableColumns { tv.removeTableColumn(c) }
                let specs = ProcCol.columns(tab, groups: groups); cols = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })
                for spec in specs {
                    let c = NSTableColumn(identifier: .init(spec.id)); c.title = spec.title; c.width = tabChanged ? spec.width : (widths[spec.id] ?? spec.width)
                    c.minWidth = 40; c.headerCell.alignment = spec.numeric ? .right : .left
                    c.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: !spec.numeric)
                    tv.addTableColumn(c)
                }
                let st = sortState[tab] ?? (ProcCol.defaultSort[tab]!, false)
                if tabChanged || tv.sortDescriptors.first?.key != st.0 { tv.sortDescriptors = [NSSortDescriptor(key: st.0, ascending: st.1)] }   // triggers resort via delegate
            }
            resort()
        }
        func resort() {
            guard let tv, let tab else { return }
            let sel = tv.selectedRow >= 0 && tv.selectedRow < sorted.count ? sorted[tv.selectedRow].id : nil
            let st = sortState[tab] ?? (ProcCol.defaultSort[tab]!, false)
            if let c = cols[st.0] { sorted = raw.sorted { st.1 ? c.less($0, $1) : c.less($1, $0) } } else { sorted = raw }
            if needsReload { needsReload = false; tv.reloadData() }
            else {
                // Update the existing cells in place; rows outside the prepared area get configured when scrolled in.
                if tv.numberOfRows != sorted.count { tv.noteNumberOfRowsChanged() }
                let rows = tv.rows(in: tv.preparedContentRect)
                for r in rows.location..<min(rows.location + rows.length, sorted.count) {
                    for (ci, col) in tv.tableColumns.enumerated() {
                        if let v = tv.view(atColumn: ci, row: r, makeIfNecessary: false) as? TextCell, let spec = cols[col.identifier.rawValue] {
                            configure(v, spec, sorted[r])
                        }
                    }
                }
            }
            if let sel, let i = sorted.firstIndex(where: { $0.id == sel }) { tv.selectRowIndexes([i], byExtendingSelection: false) }
        }
        func tableView(_ tv: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard let tab, let d = tv.sortDescriptors.first, let k = d.key else { return }
            sortState[tab] = (k, d.ascending); needsReload = true; resort()
        }
        func numberOfRows(in tv: NSTableView) -> Int { sorted.count }
        func configure(_ c: TextCell, _ spec: ProcCol, _ r: ProcRow) {
            c.hasIconSlot = spec.id == "name"
            c.alignment = spec.numeric ? .right : .left
            c.icon = c.hasIconSlot ? r.icon : nil
            c.text = spec.text(r)
        }
        func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            guard let col, let spec = cols[col.identifier.rawValue], row < sorted.count else { return nil }
            let c = (tv.makeView(withIdentifier: col.identifier, owner: nil) as? TextCell) ?? {
                let t = TextCell(); t.identifier = col.identifier; return t }()
            configure(c, spec, sorted[row]); return c
        }
    }
}

/// Small line/stacked-area chart for the summary strip.
struct MiniChart: View {
    let series: [([Double], Color)]
    var stacked = false
    var maxValue: Double? = nil
    var body: some View {
        // stacked: each series is a band on top of the ones before it (35% fill + line), like the per-core cards
        let sums: [[Double]] = stacked ? series.indices.reduce(into: []) { acc, s in
            acc.append(s == 0 ? series[0].0 : zip(acc[s - 1], series[s].0).map { $0 + $1 }) } : series.map { $0.0 }
        let peak = maxValue ?? max(sums.flatMap { $0 }.max() ?? 0, 1e-9) * 1.1
        ChartCanvas(layers: sums.indices.map { i in
            ChartLayer(data: sums[i], base: stacked && i > 0 ? sums[i - 1] : nil, color: series[i].1, fill: stacked ? 0.35 : nil)
        }, maxValue: peak)
    }
}

/// Activity Monitor-style strip under the table: stats on the left, a chart on the right.
struct ProcSummary: View {
    @ObservedObject var feed: Feed
    var m: Monitor { feed.m }
    @ObservedObject var pm: ProcMonitor
    let tab: ProcTab
    private func stat(_ k: String, _ v: String, _ c: Color = .primary) -> some View {
        GridRow { Text(k).foregroundStyle(.secondary); Text(v).monospacedDigit().foregroundStyle(c).frame(minWidth: 100, alignment: .trailing).gridColumnAlignment(.trailing) }
    }
    private func sum(_ arrs: [[Double]]) -> [Double] {
        guard let f = arrs.first else { return Array(repeating: 0, count: Monitor.historyLen) }
        return f.indices.map { i in arrs.reduce(0) { $0 + $1[i] } }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) { stats }.font(.callout).frame(width: 260, alignment: .topLeading)
            ScrollView { VStack(alignment: .leading, spacing: 4) { if tab == .energy { Text(chartTitle).font(.caption.bold()) }; chart }.frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)))
    }
    var chartTitle: String { ["CPU": "CPU LOAD", "Memory": "MEMORY USED (CPU orange · GPU cyan)", "Energy": "POWER (all processes)", "Disk": "DATA (read / write)", "Network": "DATA (received / sent)"][tab.rawValue]! }
    @ViewBuilder var stats: some View {
        switch tab {
        case .cpu:
            let s = m.cpuSys.last ?? 0, u = m.cpuUser.last ?? 0
            stat("System:", String(format: "%.2f%%", s * 100), .red)
            stat("User:", String(format: "%.2f%%", u * 100), .blue)
            stat("Idle:", String(format: "%.2f%%", max(1 - s - u, 0) * 100))
            stat("Threads:", "\(pm.threadCount)")
            stat("Processes:", "\(pm.rows.count)")
        case .memory:
            let used = m.memApp + m.memWired + m.memCompressed
            stat("Physical Memory:", String(format: "%.2f GB", m.totalMemGB))
            stat("Memory Used:", String(format: "%.2f GB", used))
            stat("  CPU / GPU:", String(format: "%.1f / %.1f GB", m.memCPU.last ?? 0, m.memGPU.last ?? 0), .orange)
            stat("Cached Files:", String(format: "%.2f GB", m.memCached))
            stat("Swap Used:", String(format: "%.2f GB", m.swapUsed))
            stat("App / Wired / Compressed:", String(format: "%.1f / %.1f / %.1f", m.memApp, m.memWired, m.memCompressed))
        case .energy:
            stat("Power now:", String(format: "%.2f W", pm.powerHist.last ?? 0), .green)
            stat("Avg (last min):", String(format: "%.2f W", pm.powerHist.reduce(0, +) / Double(pm.powerHist.count)))
            stat("Top process:", pm.rows.max { $0.power < $1.power }?.name ?? "–")
            stat("Chip temp:", m.chipC.map { "\(Int($0.rounded())) °C" } ?? "–")
        case .disk:
            let r = sum(m.disks.map { $0.read }), w = sum(m.disks.map { $0.write })
            stat("Reads/sec:", fmtRate(r.last ?? 0), .blue)
            stat("Writes/sec:", fmtRate(w.last ?? 0), .red)
            stat("Data read (procs):", fmtBytes(pm.rows.reduce(0) { $0 + $1.diskReadTotal }))
            stat("Data written (procs):", fmtBytes(pm.rows.reduce(0) { $0 + $1.diskWriteTotal }))
        case .network:
            let d = sum(m.nets.map { $0.down }), u = sum(m.nets.map { $0.up })
            stat("Data received/sec:", fmtRate(d.last ?? 0), .blue)
            stat("Data sent/sec:", fmtRate(u.last ?? 0), .red)
            stat("Data received (procs):", fmtBytes(pm.rows.reduce(0) { $0 + $1.netInTotal }))
            stat("Data sent (procs):", fmtBytes(pm.rows.reduce(0) { $0 + $1.netOutTotal }))
        }
    }
    /// The matching graphs from the Graphs page (reused directly so the two stay identical).
    @ViewBuilder var chart: some View {
        let g = ContentView(feed: feed)
        switch tab {
        case .cpu: g.cpuSection
        // Just the stacked CPU/GPU graph, at the same height as the other cards (the readout on the left has the numbers).
        case .memory: StackedGraph(title: "Used", bottom: m.memCPU, top: m.memGPU, total: m.totalMemGB,
                                   bottomLabel: "CPU", topLabel: "GPU", bottomColor: .orange, topColor: .cyan, height: 120)
        case .energy: MiniChart(series: [(pm.powerHist, .green)], stacked: true).frame(height: 120)
        case .disk: g.drivesSection
        case .network: g.netSection
        }
    }
}

final class RootUI: ObservableObject { @Published var page = "Graphs" }

/// Re-publishes Monitor's 1 s updates only while its page is visible, so the hidden page doesn't redraw.
final class Feed: ObservableObject {
    let m: Monitor
    private(set) var active: Bool
    private var sub: AnyCancellable?
    init(_ m: Monitor, active: Bool = true) {
        self.m = m; self.active = active
        sub = m.objectWillChange.sink { [weak self] _ in if self?.active == true { self?.objectWillChange.send() } }
    }
    func setActive(_ a: Bool) { guard a != active else { return }; active = a; if a { objectWillChange.send() } }
}

/// Owns the long-lived models (created exactly once, unlike values built in a View's init).
final class AppModel: ObservableObject {
    let m = Monitor()
    let pm = ProcMonitor()
    lazy var graphsFeed = Feed(m, active: true)
    lazy var procFeed = Feed(m, active: false)
}

/// Both pages stay alive and are just shown/hidden, so switching never rebuilds the process table or the graphs.
struct RootView: View {
    @StateObject var app = AppModel()
    @StateObject var ui = RootUI()
    var body: some View {
        ZStack {
            ContentView(feed: app.graphsFeed).opacity(ui.page == "Graphs" ? 1 : 0).allowsHitTesting(ui.page == "Graphs")
            ProcessesView(feed: app.procFeed, pm: app.pm).opacity(ui.page == "Processes" ? 1 : 0).allowsHitTesting(ui.page == "Processes")
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $ui.page.deferred) { Text("Graphs").tag("Graphs"); Text("Processes").tag("Processes") }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        .onChange(of: ui.page) { _, page in
            app.graphsFeed.setActive(page == "Graphs"); app.procFeed.setActive(page == "Processes")
            app.pm.setVisible(page == "Processes")
        }
        .frame(minWidth: 900, minHeight: 760)
    }
}
