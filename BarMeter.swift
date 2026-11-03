// BarMeter — 极简 macOS 状态栏系统监控（CPU / 内存 / 硬盘 / 网络）
//
// 设计原则：
//   - 纯 AppKit + 系统调用（mach / sysctl / getifaddrs / IOKit / libproc），无第三方依赖
//   - 只有一个主线程定时器，无后台线程、无网络请求、不写日志
//   - 状态栏默认「详细」样式（曲线 + 两行详情，约 670 点宽），可切换「紧凑」样式
//   - 状态栏的「最吃内存」约每 6 秒扫一次进程；下拉菜单里的完整排行只在菜单打开时计算
//   - 所有计数器都做了回绕 / 归零 / 睡眠唤醒处理，长期运行不会出现离谱数值

import AppKit
import Darwin
import IOKit

let kBundleID = "com.paxfi.barmeter"

enum Level { case normal, warn, critical }

func levelColor(_ l: Level) -> NSColor {
    switch l {
    case .normal: return .labelColor
    case .warn: return .systemOrange
    case .critical: return .systemRed
    }
}

/// 单调时钟（纳秒，包含睡眠时间），用来算速率
@inline(__always) func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }

// MARK: - 格式化

enum Fmt {
    static func pct(_ v: Double) -> String { "\(Int((max(0, v) * 100).rounded()))%" }

    /// 状态栏短速率，最多 4 个字符，宽度稳定：0K / 999K / 9.9M / 999M / 1.2G
    static func rateShort(_ bps: Double) -> String {
        let kb = max(0, bps) / 1000
        if kb < 999.5 { return "\(Int(kb.rounded()))K" }
        let mb = kb / 1000
        if mb < 9.95 { return String(format: "%.1fM", mb) }
        if mb < 999.5 { return "\(Int(mb.rounded()))M" }
        return String(format: "%.1fG", mb / 1000)
    }

    /// 十进制容量（硬盘、网络，与访达/活动监视器一致）
    static func bytes(_ b: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = max(0, b)
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return "\(Int(v)) B" }
        return String(format: v < 10 ? "%.1f" : "%.0f", v) + " " + units[i]
    }

    static func rate(_ bps: Double) -> String { bytes(bps) + "/s" }

    /// 二进制容量（内存）
    static func mem(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(b) / 1_048_576)
    }
}

// MARK: - CPU

final class CPUMeter {
    struct Reading { var total = 0.0; var user = 0.0; var system = 0.0 }

    private let host: host_t
    private var last: (UInt32, UInt32, UInt32, UInt32)?

    init(host: host_t) { self.host = host }
    func reset() { last = nil }

    func read() -> Reading? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p -> kern_return_t in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks                       // USER, SYSTEM, IDLE, NICE
        let cur = (t.0, t.1, t.2, t.3)
        defer { last = cur }
        guard let p = last else { return nil }
        // tick 计数是 32 位，长时间开机会回绕，用环绕减法
        let user = Double(cur.0 &- p.0) + Double(cur.3 &- p.3)
        let sys = Double(cur.1 &- p.1)
        let idle = Double(cur.2 &- p.2)
        let total = user + sys + idle
        guard total > 0 else { return nil }
        return Reading(total: (user + sys) / total, user: user / total, system: sys / total)
    }
}

// MARK: - 内存（口径与「活动监视器」一致）

struct MemReading {
    var total: UInt64 = 0
    var used: UInt64 = 0        // App 内存 + 联动内存 + 被压缩
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: Level = .normal
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

final class MemMeter {
    private let host: host_t
    private let pageSize: UInt64
    private let total = ProcessInfo.processInfo.physicalMemory

    init(host: host_t) {
        self.host = host
        var ps: vm_size_t = 0
        host_page_size(host, &ps)
        pageSize = ps > 0 ? UInt64(ps) : 16384
    }

    func read() -> MemReading? {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &s) { p -> kern_return_t in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let internalPages = UInt64(s.internal_page_count)
        let purgeable = UInt64(s.purgeable_count)
        var r = MemReading()
        r.total = total
        r.app = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
        r.wired = UInt64(s.wire_count) * pageSize
        r.compressed = UInt64(s.compressor_page_count) * pageSize
        r.cached = (UInt64(s.external_page_count) + purgeable) * pageSize
        r.used = min(r.app + r.wired + r.compressed, total)

        var sw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &size, nil, 0) == 0 { r.swapUsed = sw.xsu_used }

        // 内存压力：1 正常 / 2 警告 / 4 严重（活动监视器里那条绿/黄/红的线）
        var lvl: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl, &size, nil, 0) == 0 {
            r.pressure = lvl >= 4 ? .critical : (lvl >= 2 ? .warn : .normal)
        }
        return r
    }
}

// MARK: - 硬盘

final class DiskMeter {
    private var lastIO: (r: UInt64, w: UInt64, t: UInt64)?

    func resetIO() { lastIO = nil }

    /// 启动盘所在 APFS 容器的总量 / 可用（f_bavail 是容器级共享的可用空间）
    func space() -> (total: UInt64, free: UInt64)? {
        var s = statfs()
        guard statfs("/", &s) == 0 else { return nil }
        let bs = UInt64(s.f_bsize)
        let total = UInt64(s.f_blocks) * bs
        guard total > 0 else { return nil }
        return (total, UInt64(s.f_bavail) * bs)
    }

    /// 所有块设备累计读写字节（与 iostat 同一数据源）
    private func ioTotals() -> (UInt64, UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var r: UInt64 = 0, w: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let prop = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSDictionary {
                r &+= (prop["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w &+= (prop["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (r, w)
    }

    func ioRates(now: UInt64) -> (read: Double, write: Double)? {
        guard let io = ioTotals() else { return nil }
        defer { lastIO = (io.0, io.1, now) }
        guard let l = lastIO, now > l.t else { return nil }
        let dt = Double(now - l.t) / 1e9
        // 外接盘拔掉时总数会变小，按 0 处理
        let dr = io.0 >= l.r ? io.0 - l.r : 0
        let dw = io.1 >= l.w ? io.1 - l.w : 0
        return (Double(dr) / dt, Double(dw) / dt)
    }
}

// MARK: - 网络

final class NetMeter {
    private struct Sample { var rx: UInt32; var tx: UInt32; var changed: Int64 }
    private var last: [String: Sample] = [:]
    private var lastT: UInt64 = 0

    func reset() { last = [:]; lastT = 0 }

    /// 只统计 en*（Wi-Fi / 有线），不算 lo0，也不算 utun 等 VPN 虚拟网卡，避免重复计算
    func rates(now: UInt64) -> (down: Double, up: Double)? {
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }

        var cur: [String: Sample] = [:]
        var p = ifap
        while let ifa = p {
            let e = ifa.pointee
            if let addr = e.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let data = e.ifa_data, (e.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
                let name = String(cString: e.ifa_name)
                if name.hasPrefix("en") {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    let changed = (Int64(d.ifi_lastchange.tv_sec) << 20) ^ Int64(d.ifi_lastchange.tv_usec)
                    cur[name] = Sample(rx: d.ifi_ibytes, tx: d.ifi_obytes, changed: changed)
                }
            }
            p = e.ifa_next
        }

        defer { last = cur; lastT = now }
        guard lastT > 0, now > lastT else { return nil }
        var down: UInt64 = 0, up: UInt64 = 0
        for (k, v) in cur {
            guard let o = last[k] else { continue }
            // 网卡被拔插 / 重建时计数会清零（同时 ifi_lastchange 会变），这一轮按 0 算，避免显示假尖峰
            if o.changed != v.changed && (v.rx < o.rx || v.tx < o.tx) { continue }
            // if_data 的字节计数是 32 位，4GB 回绕，用环绕减法（刷新间隔 ≤3 秒，10GbE 跑满也不会回绕两次）
            down += UInt64(v.rx &- o.rx)
            up += UInt64(v.tx &- o.tx)
        }
        let dt = Double(now - lastT) / 1e9
        return (Double(down) / dt, Double(up) / dt)
    }
}

// MARK: - 进程排行（仅菜单打开时）

struct ProcGroup {
    let name: String
    var footprint: UInt64 = 0   // 与活动监视器「内存」列同口径
    var cpu: Double = 0         // 1.0 = 一个核满载
    var count = 0
}

final class ProcMeter {
    private let tbRatio: Double
    private var names: [pid_t: String] = [:]
    private var lastCPU: [pid_t: UInt64] = [:]
    private var lastT: UInt64 = 0

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        tbRatio = tb.denom > 0 ? Double(tb.numer) / Double(tb.denom) : 1
    }

    func reset() { names = [:]; lastCPU = [:]; lastT = 0 }

    /// 返回按内存排序的前 n 名；第二次起才有 CPU 排行（需要两次采样求差）。
    /// 距上次采样不足 0.8 秒时返回 nil（窗口太短 CPU 数值会乱跳），调用方保留上次结果即可。
    func sample(now: UInt64, top: Int = 6) -> (mem: [ProcGroup], cpu: [ProcGroup]?)? {
        if lastT > 0 && now > lastT && now - lastT < 800_000_000 { return nil }
        let estimate = Int(proc_listallpids(nil, 0))
        guard estimate > 0 else { return ([], nil) }
        var pids = [pid_t](repeating: 0, count: estimate + 64)
        let n = pids.withUnsafeMutableBytes { buf -> Int in
            Int(proc_listallpids(buf.baseAddress, Int32(buf.count)))
        }
        guard n > 0 else { return ([], nil) }

        let dt = (lastT > 0 && now > lastT) ? Double(now - lastT) : 0
        var groups: [String: ProcGroup] = [:]
        var curCPU: [pid_t: UInt64] = [:]
        var liveNames: [pid_t: String] = [:]
        curCPU.reserveCapacity(n)
        liveNames.reserveCapacity(n)

        for i in 0..<min(n, pids.count) {
            let pid = pids[i]
            if pid <= 0 { continue }
            var ri = rusage_info_v2()
            let rc = withUnsafeMutablePointer(to: &ri) { p -> Int32 in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            if rc != 0 { continue }   // 其他用户 / 系统进程读不到，跳过

            let name = names[pid] ?? groupName(pid)
            liveNames[pid] = name
            // ri_user_time / ri_system_time 是 mach 时间单位，Apple Silicon 上需要换算成纳秒
            let cpuNs = UInt64(Double(ri.ri_user_time &+ ri.ri_system_time) * tbRatio)
            curCPU[pid] = cpuNs

            var g = groups[name] ?? ProcGroup(name: name)
            g.footprint &+= ri.ri_phys_footprint
            g.count += 1
            if dt > 0, let old = lastCPU[pid], cpuNs >= old {
                g.cpu += Double(cpuNs - old) / dt
            }
            groups[name] = g
        }

        let hadBase = dt > 0
        names = liveNames
        lastCPU = curCPU
        lastT = now

        let all = Array(groups.values)
        let mem = Array(all.sorted { $0.footprint > $1.footprint }.prefix(top))
        let cpu = hadBase ? Array(all.sorted { $0.cpu > $1.cpu }.prefix(top)) : nil
        return (mem, cpu)
    }

    /// 把同一个 App 的所有子进程归到一起（例如 Chrome 的几十个 Helper 合并成「Google Chrome」）
    private func groupName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if let r = path.range(of: ".app/") {
                let prefix = path[..<r.lowerBound]
                if let slash = prefix.lastIndex(of: "/") {
                    return String(prefix[prefix.index(after: slash)...])
                }
                return String(prefix)
            }
            if path.contains("/WebKit.framework/") { return "WebKit 网页进程" }
            return (path as NSString).lastPathComponent
        }
        var nb = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &nb, UInt32(nb.count)) > 0 {
            return nb.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        return "pid \(pid)"
    }
}

// MARK: - 开机自启（LaunchAgent，崩溃后由 launchd 自动拉起）

enum LoginItem {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(kBundleID).plist")
    }

    static var isOn: Bool { FileManager.default.fileExists(atPath: url.path) }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard on else {
            try? FileManager.default.removeItem(at: url)
            return !isOn
        }
        guard let exe = Bundle.main.executablePath else { return false }
        let plist: [String: Any] = [
            "Label": kBundleID,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            // 异常退出 / 崩溃时自动重启；菜单里点「退出」属于正常退出，不会被拉起
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
        ]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// App 被挪了位置时，修正开机启动里记录的路径
    static func repairPathIfNeeded() {
        guard isOn, let exe = Bundle.main.executablePath else { return }
        if let d = NSDictionary(contentsOf: url),
           let args = d["ProgramArguments"] as? [String], args.first == exe { return }
        set(true)
    }
}

// MARK: - 状态栏视图

func cpuLevel(_ v: Double) -> Level { v >= 0.9 ? .critical : (v >= 0.7 ? .warn : .normal) }
func diskLevel(_ v: Double) -> Level { v >= 0.95 ? .critical : (v >= 0.85 ? .warn : .normal) }

/// 固定长度的历史队列（迷你曲线用，30 个点 ≈ 默认 2 秒间隔下的最近 60 秒）
struct History {
    private(set) var values: [Double] = []
    let capacity: Int
    init(capacity: Int = 30) { self.capacity = capacity; values.reserveCapacity(capacity) }
    mutating func push(_ v: Double) {
        if values.count >= capacity { values.removeFirst(values.count - capacity + 1) }
        values.append(max(0, v))
    }
}

/// 状态栏要画的全部数据
struct BarModel {
    var cpu: CPUMeter.Reading?
    var load: Double?
    var mem: MemReading?
    var disk: (total: UInt64, free: UInt64)?
    var io: (read: Double, write: Double)?
    var net: (down: Double, up: Double)?
    var topName: String?
    var topBytes: UInt64 = 0
    var cpuHist = History(), memHist = History(), downHist = History(), upHist = History()

    var diskUsed: Double? {
        guard let d = disk, d.total > 0 else { return nil }
        return 1 - Double(min(d.free, d.total)) / Double(d.total)
    }
}

enum Short {
    /// 内存 / 交换：2.1G、640M
    static func mem(_ b: UInt64) -> String {
        let g = Double(b) / 1_073_741_824
        return g >= 1 ? String(format: "%.1fG", g) : String(format: "%.0fM", Double(b) / 1_048_576)
    }
    /// 硬盘剩余（十进制）：192G、1.2T
    static func disk(_ b: UInt64) -> String {
        let g = Double(b) / 1e9
        return g >= 1000 ? String(format: "%.1fT", g / 1000) : String(format: "%.0fG", g)
    }
}

final class BarView: NSView {
    var detailed = true
    var showCPU = true, showMem = true, showDisk = true, showNet = true, showTop = true
    var model = BarModel()

    // 紧凑样式字体
    private let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private let netFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    // 详细样式字体
    private let dTop = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold)
    private let dValue = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    private let dSub = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
    private let dName = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    private let dNet = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)

    private let gap: CGFloat = 6
    private let pad: CGFloat = 4
    // 详细样式的几何尺寸（点）
    private let sparkW: CGFloat = 35, sparkH: CGFloat = 16
    private let capsuleW: CGFloat = 6
    private let netGraphW: CGFloat = 70, netGraphH: CGFloat = 19
    private let innerGap: CGFloat = 5
    private let sepGap: CGFloat = 8
    private let topW: CGFloat = 92

    private func tw(_ s: String, _ f: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }

    // 每一段用「最宽可能的样本」预先算出固定宽度：数值变化时状态栏不会左右抖动
    private lazy var cellW: CGFloat = max(self.tw("100%", self.valueFont), self.tw("MEM", self.labelFont)) + 1
    private lazy var netW: CGFloat = self.tw("↓ 999K", self.netFont) + 1
    private lazy var cpuTextW: CGFloat = max(self.tw("CPU · 负载 88.88", self.dTop), self.tw("100%", self.dValue) + 4 + self.tw("用户 100 · 系统 100", self.dSub))
    private lazy var memTextW: CGFloat = max(self.tw("内存 · 压力偏高", self.dTop), self.tw("100%", self.dValue) + 4 + self.tw("88.8/88G · 交换 88.8G", self.dSub))
    private lazy var diskTextW: CGFloat = max(self.tw("硬盘 · 剩 888G", self.dTop), self.tw("100%", self.dValue) + 4 + self.tw("读 999K · 写 999K", self.dSub))
    private lazy var netTextW: CGFloat = self.tw("↓ 888 MB/s", self.dNet)

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // 点击交给状态栏按钮处理
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    private var detailedSections: [CGFloat] {
        var s: [CGFloat] = []
        if showCPU { s.append(sparkW + innerGap + cpuTextW) }
        if showMem { s.append(sparkW + innerGap + memTextW) }
        if showDisk { s.append(capsuleW + innerGap + diskTextW) }
        if showNet { s.append(netGraphW + innerGap + netTextW) }
        if showTop { s.append(topW) }
        return s
    }

    var preferredWidth: CGFloat {
        if detailed {
            let s = detailedSections
            guard !s.isEmpty else { return 20 }
            return s.reduce(0, +) + CGFloat(s.count - 1) * (sepGap * 2 + 1) + pad * 2
        }
        var w: CGFloat = 0
        var n = 0
        for on in [showCPU, showMem, showDisk] where on { w += cellW; n += 1 }
        if showNet { w += netW; n += 1 }
        guard n > 0 else { return 20 }
        return w + gap * CGFloat(n - 1) + pad * 2
    }

    override func draw(_ dirtyRect: NSRect) {
        if detailed { drawDetailed() } else { drawCompact() }
    }

    // MARK: 紧凑样式（两行小字）

    private func drawCompact() {
        let m = model
        let labelH = ceil(labelFont.ascender - labelFont.descender)
        let valueH = ceil(valueFont.ascender - valueFont.descender)
        let top = floor((bounds.height - labelH - valueH) / 2)
        var x = pad

        func cell(_ label: String, _ text: String, _ level: Level) {
            let la: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.labelColor]
            let va: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: levelColor(level)]
            let ls = (label as NSString).size(withAttributes: la)
            (label as NSString).draw(at: NSPoint(x: x + (cellW - ls.width) / 2, y: top), withAttributes: la)
            let vs = (text as NSString).size(withAttributes: va)
            (text as NSString).draw(at: NSPoint(x: x + (cellW - vs.width) / 2, y: top + labelH - 1), withAttributes: va)
            x += cellW + gap
        }

        if showCPU { cell("CPU", m.cpu.map { Fmt.pct($0.total) } ?? "--", m.cpu.map { cpuLevel($0.total) } ?? .normal) }
        if showMem { cell("MEM", m.mem.map { Fmt.pct($0.usedFraction) } ?? "--", m.mem?.pressure ?? .normal) }
        if showDisk { cell("SSD", m.diskUsed.map { Fmt.pct($0) } ?? "--", m.diskUsed.map { diskLevel($0) } ?? .normal) }

        if showNet {
            let lineH = ceil(netFont.ascender - netFont.descender)
            let nTop = floor((bounds.height - lineH * 2) / 2)
            let a: [NSAttributedString.Key: Any] = [.font: netFont, .foregroundColor: NSColor.labelColor]
            let up = m.net.map { Fmt.rateShort($0.up) } ?? "--"
            let down = m.net.map { Fmt.rateShort($0.down) } ?? "--"
            for (i, pair) in [("↑", up), ("↓", down)].enumerated() {
                let y = nTop + CGFloat(i) * lineH
                (pair.0 as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: a)
                let s = (pair.1 as NSString).size(withAttributes: a)
                (pair.1 as NSString).draw(at: NSPoint(x: x + netW - s.width, y: y), withAttributes: a)
            }
        }
    }

    // MARK: 详细样式（方案 D：曲线 + 两行详情）

    private func drawDetailed() {
        let m = model
        let fg = NSColor.labelColor
        let sub = NSColor.secondaryLabelColor
        let track = NSColor.labelColor.withAlphaComponent(0.2)
        let topH = ceil(dTop.ascender - dTop.descender)
        let valH = ceil(dValue.ascender - dValue.descender)
        let textTop = floor((bounds.height - (topH + valH - 1)) / 2)
        let valY = textTop + topH - 1
        let subY = valY + (dValue.ascender - dSub.ascender)
        let midY = bounds.height / 2
        var x = pad
        var first = true

        func separator() {
            if first { first = false; return }
            track.setFill()
            NSRect(x: x + sepGap, y: floor(midY - 6.5), width: 1, height: 13).fill()
            x += sepGap * 2 + 1
        }
        func drawTop(_ parts: [(String, NSColor)], at px: CGFloat, width: CGFloat) {
            let s = NSMutableAttributedString()
            for (t, c) in parts { s.append(NSAttributedString(string: t, attributes: [.font: dTop, .foregroundColor: c])) }
            s.draw(in: NSRect(x: px, y: textTop, width: width, height: topH))
        }
        func drawValue(_ value: String, _ color: NSColor, _ detail: String, at px: CGFloat) {
            (value as NSString).draw(at: NSPoint(x: px, y: valY), withAttributes: [.font: dValue, .foregroundColor: color])
            let vw = tw(value, dValue)
            (detail as NSString).draw(at: NSPoint(x: px + vw + 4, y: subY), withAttributes: [.font: dSub, .foregroundColor: sub])
        }

        if showCPU {
            separator()
            let c = m.cpu
            let lvl = c.map { cpuLevel($0.total) } ?? .normal
            drawSeries(m.cpuHist.values, maxValue: 1, rect: NSRect(x: x, y: floor(midY - sparkH / 2), width: sparkW, height: sparkH), color: fg, fromBottom: true)
            let tx = x + sparkW + innerGap
            drawTop([("CPU · 负载 " + (m.load.map { String(format: "%.2f", $0) } ?? "--"), sub)], at: tx, width: cpuTextW)
            drawValue(c.map { Fmt.pct($0.total) } ?? "--", levelColor(lvl),
                      c.map { "用户 \(Int(($0.user * 100).rounded())) · 系统 \(Int(($0.system * 100).rounded()))" } ?? "", at: tx)
            x += sparkW + innerGap + cpuTextW
        }

        if showMem {
            separator()
            let p = m.mem?.pressure ?? .normal
            let memColor = levelColor(p)
            drawSeries(m.memHist.values, maxValue: 1, rect: NSRect(x: x, y: floor(midY - sparkH / 2), width: sparkW, height: sparkH), color: memColor, fromBottom: true)
            let tx = x + sparkW + innerGap
            let pText: (String, NSColor) = {
                switch p {
                case .normal: return ("压力正常", sub)
                case .warn: return ("压力偏高", NSColor.systemOrange)
                case .critical: return ("压力紧张", NSColor.systemRed)
                }
            }()
            drawTop([("内存 · ", sub), pText], at: tx, width: memTextW)
            if let mm = m.mem {
                let totalG = String(format: "%.0fG", Double(mm.total) / 1_073_741_824)
                let usedG = String(format: "%.1f", Double(mm.used) / 1_073_741_824)
                drawValue(Fmt.pct(mm.usedFraction), memColor, "\(usedG)/\(totalG) · 交换 \(Short.mem(mm.swapUsed))", at: tx)
            } else {
                drawValue("--", fg, "", at: tx)
            }
            x += sparkW + innerGap + memTextW
        }

        if showDisk {
            separator()
            let u = m.diskUsed
            let lvl = u.map { diskLevel($0) } ?? .normal
            let cap = NSRect(x: x, y: floor(midY - sparkH / 2), width: capsuleW, height: sparkH)
            track.setFill()
            NSBezierPath(roundedRect: cap, xRadius: capsuleW / 2, yRadius: capsuleW / 2).fill()
            if let u = u {
                let fh = max(capsuleW, cap.height * CGFloat(u))
                (lvl == .normal ? fg : levelColor(lvl)).setFill()
                NSBezierPath(roundedRect: NSRect(x: cap.minX, y: cap.maxY - fh, width: capsuleW, height: fh), xRadius: capsuleW / 2, yRadius: capsuleW / 2).fill()
            }
            let tx = x + capsuleW + innerGap
            drawTop([("硬盘 · 剩 " + (m.disk.map { Short.disk($0.free) } ?? "--"), sub)], at: tx, width: diskTextW)
            let io = m.io.map { "读 \(Fmt.rateShort($0.read)) · 写 \(Fmt.rateShort($0.write))" } ?? "读 -- · 写 --"
            drawValue(u.map { Fmt.pct($0) } ?? "--", levelColor(lvl), io, at: tx)
            x += capsuleW + innerGap + diskTextW
        }

        if showNet {
            separator()
            let g = NSRect(x: x, y: floor(midY - netGraphH / 2), width: netGraphW, height: netGraphH)
            let half = g.height / 2
            let downMax = max(50_000, m.downHist.values.max() ?? 0)
            let upMax = max(50_000, m.upHist.values.max() ?? 0)
            drawSeries(m.downHist.values, maxValue: downMax, rect: NSRect(x: g.minX, y: g.minY, width: g.width, height: half), color: .systemBlue, fromBottom: true)
            drawSeries(m.upHist.values, maxValue: upMax, rect: NSRect(x: g.minX, y: g.minY + half, width: g.width, height: half), color: .systemOrange, fromBottom: false)
            track.setFill()
            NSRect(x: g.minX, y: g.minY + half - 0.25, width: g.width, height: 0.5).fill()

            let tx = x + netGraphW + innerGap
            let lineH = ceil(dNet.ascender - dNet.descender)
            let nTop = floor((bounds.height - lineH * 2) / 2)
            let down = "↓ " + (m.net.map { Fmt.rate($0.down) } ?? "--")
            let up = "↑ " + (m.net.map { Fmt.rate($0.up) } ?? "--")
            for (i, pair) in [(down, NSColor.systemBlue), (up, NSColor.systemOrange)].enumerated() {
                let a: [NSAttributedString.Key: Any] = [.font: dNet, .foregroundColor: pair.1]
                let w = tw(pair.0, dNet)
                (pair.0 as NSString).draw(at: NSPoint(x: tx + netTextW - w, y: nTop + CGFloat(i) * lineH), withAttributes: a)
            }
            x += netGraphW + innerGap + netTextW
        }

        if showTop {
            separator()
            drawTop([("最吃内存", sub)], at: x, width: topW)
            let size = m.topName == nil ? "" : Short.mem(m.topBytes)
            let sizeW = size.isEmpty ? 0 : tw(size, dSub) + 4
            let name = m.topName ?? "--"
            let nameMax = topW - sizeW
            let ps = NSMutableParagraphStyle()
            ps.lineBreakMode = .byTruncatingTail
            let na: [NSAttributedString.Key: Any] = [.font: dName, .foregroundColor: fg, .paragraphStyle: ps]
            let nameW = min(nameMax, tw(name, dName))
            let nameY = valY + (dValue.ascender - dName.ascender)
            (name as NSString).draw(in: NSRect(x: x, y: nameY, width: nameMax, height: ceil(dName.ascender - dName.descender)), withAttributes: na)
            if !size.isEmpty {
                (size as NSString).draw(at: NSPoint(x: x + nameW + 4, y: subY), withAttributes: [.font: dSub, .foregroundColor: sub])
            }
            x += topW
        }
    }

    /// 画一条迷你曲线（带浅色填充）。最新的点在最右边；fromBottom=false 时从顶边往下长（上行流量用）
    private func drawSeries(_ vals: [Double], maxValue: Double, rect: NSRect, color: NSColor, fromBottom: Bool) {
        guard vals.count >= 2, maxValue > 0 else { return }
        let dx = rect.width / CGFloat(29)
        let base = fromBottom ? rect.maxY : rect.minY
        let line = NSBezierPath()
        var firstX: CGFloat = rect.maxX
        for (i, v) in vals.enumerated() {
            let px = rect.maxX - CGFloat(vals.count - 1 - i) * dx
            let k = CGFloat(min(1, v / maxValue))
            let py = fromBottom ? base - k * rect.height : base + k * rect.height
            if i == 0 { line.move(to: NSPoint(x: px, y: py)); firstX = px } else { line.line(to: NSPoint(x: px, y: py)) }
        }
        if let area = line.copy() as? NSBezierPath {
            area.line(to: NSPoint(x: rect.maxX, y: base))
            area.line(to: NSPoint(x: firstX, y: base))
            area.close()
            color.withAlphaComponent(0.2).setFill()
            area.fill()
        }
        line.lineWidth = 1
        line.lineJoinStyle = .round
        color.setStroke()
        line.stroke()
    }
}

// MARK: - 菜单里的信息行（自绘，不会被鼠标高亮，可实时刷新）

final class RowView: NSView {
    private let header: Bool
    private var left = ""
    private var right = ""
    private var rightColor: NSColor = .labelColor

    init(header: Bool = false) {
        self.header = header
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: header ? 22 : 18))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func set(_ l: String, _ r: String, color: NSColor = .labelColor) {
        if l == left && r == right && color == rightColor { return }
        left = l; right = r; rightColor = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let lf: NSFont = header ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 12)
        let rf: NSFont = header ? .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
                                : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let ra: [NSAttributedString.Key: Any] = [.font: rf, .foregroundColor: rightColor]
        let rs = (right as NSString).size(withAttributes: ra)
        (right as NSString).draw(at: NSPoint(x: bounds.width - 14 - rs.width, y: (bounds.height - rs.height) / 2), withAttributes: ra)

        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        let la: [NSAttributedString.Key: Any] = [
            .font: lf,
            .foregroundColor: header ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: ps,
        ]
        let lx: CGFloat = header ? 14 : 26
        let lh = (left as NSString).size(withAttributes: la).height
        let lw = max(10, bounds.width - lx - rs.width - 14 - 10)
        (left as NSString).draw(in: NSRect(x: lx, y: (bounds.height - lh) / 2, width: lw, height: lh), withAttributes: la)
    }
}

// MARK: - App

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    /// 单实例锁：文件锁是原子的，两个副本同时启动也只会留下一个；进程退出时系统自动释放
    private static var lockFD: Int32 = -1

    static func main() {
        let lockPath = NSTemporaryDirectory() + kBundleID + ".lock"
        lockFD = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o644)
        if lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) != 0 { exit(0) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private let bar = BarView()
    private let menu = NSMenu()
    private var timer: Timer?
    private var quickTimer: Timer?
    private var menuOpen = false

    private let host = mach_host_self()          // 只取一次，避免 mach 端口引用泄漏
    private lazy var cpuMeter = CPUMeter(host: host)
    private lazy var memMeter = MemMeter(host: host)
    private let diskMeter = DiskMeter()
    private let netMeter = NetMeter()
    private let procMeter = ProcMeter()      // 菜单里的排行用
    private let topMeter = ProcMeter()       // 状态栏「最吃内存」用，每 3 次采样扫一次进程
    private var tickCount = 0

    private var lastCPU: CPUMeter.Reading?
    private var lastMem: MemReading?
    private var lastSpace: (total: UInt64, free: UInt64)?
    private var lastIO: (read: Double, write: Double)?
    private var lastNet: (down: Double, up: Double)?

    // 菜单信息行
    private let cpuRow = RowView(header: true)
    private let cpuSplitRow = RowView()
    private let loadRow = RowView()
    private let memRow = RowView(header: true)
    private let pressureRow = RowView()
    private let appMemRow = RowView()
    private let wiredRow = RowView()
    private let compRow = RowView()
    private let cachedRow = RowView()
    private let swapRow = RowView()
    private let diskRow = RowView(header: true)
    private let diskFreeRow = RowView()
    private let diskIORow = RowView()
    private let netRow = RowView(header: true)
    private let netDownRow = RowView()
    private let netUpRow = RowView()
    private let memTopHeader = RowView(header: true)
    private let cpuTopHeader = RowView(header: true)
    private var memTopItems: [(NSMenuItem, RowView)] = []
    private var cpuTopItems: [(NSMenuItem, RowView)] = []

    private var showItems: [NSMenuItem] = []
    private var intervalItems: [NSMenuItem] = []
    private let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(AppDelegate.toggleLogin(_:)), keyEquivalent: "")

    private static let showKeys = ["showCPU", "showMem", "showDisk", "showNet", "showTop"]
    private var styleItems: [NSMenuItem] = []

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["interval": 2.0, "style": "detailed", "showCPU": true, "showMem": true,
                                     "showDisk": true, "showNet": true, "showTop": true, "loginSetupDone": false])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "BarMeter"
        if let b = statusItem.button {
            b.title = ""
            b.image = nil
            b.setAccessibilityLabel("BarMeter 系统监控")
            bar.autoresizingMask = [.height]
            b.addSubview(bar)
        }
        buildMenu()
        statusItem.menu = menu
        applyVisibility()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)

        // 第一次运行时默认打开「开机自动启动」；之后以菜单里的开关为准
        if !defaults.bool(forKey: "loginSetupDone") {
            LoginItem.set(true)
            defaults.set(true, forKey: "loginSetupDone")
        }
        LoginItem.repairPathIfNeeded()

        tick()          // 建立基线
        startTimer()
    }

    /// 刷新间隔 1–3 秒（网卡计数是 32 位，间隔再长 10GbE 跑满时可能回绕两次）
    private var interval: Double { min(3, max(1, defaults.double(forKey: "interval"))) }

    private func startTimer() {
        timer?.invalidate()
        let iv = interval
        let t = Timer(timeInterval: iv, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = iv * 0.1      // 允许系统合并唤醒，更省电
        RunLoop.main.add(t, forMode: .common)   // .common：菜单打开时也继续刷新
        timer = t
    }

    @objc private func didWake(_ n: Notification) {
        cpuMeter.reset(); netMeter.reset(); diskMeter.resetIO(); procMeter.reset(); topMeter.reset()
    }

    // MARK: 采样

    @objc private func tick() {
        let now = nowNs()
        if let c = cpuMeter.read() { lastCPU = c }
        if let m = memMeter.read() { lastMem = m }
        if let s = diskMeter.space() { lastSpace = s }
        if let n = netMeter.rates(now: now) { lastNet = n }
        if let io = diskMeter.ioRates(now: now) { lastIO = io }
        var la = [Double](repeating: 0, count: 3)
        bar.model.load = getloadavg(&la, 3) == 3 ? la[0] : nil

        if let c = lastCPU { bar.model.cpuHist.push(c.total) }
        if let m = lastMem { bar.model.memHist.push(m.usedFraction) }
        if let n = lastNet { bar.model.downHist.push(n.down); bar.model.upHist.push(n.up) }

        // 「最吃内存」：只在详细样式且开着这一项时才扫进程，约每 3 次采样一次
        if bar.detailed && bar.showTop {
            if tickCount % 3 == 0, let r = topMeter.sample(now: now), let g = r.mem.first {
                bar.model.topName = g.name
                bar.model.topBytes = g.footprint
            }
        }
        tickCount &+= 1

        updateBar()
        if menuOpen {
            refreshTop(now: now)
            updateMenu()
        }
    }

    private func diskUsed(_ s: (total: UInt64, free: UInt64)) -> Double {
        s.total > 0 ? 1 - Double(min(s.free, s.total)) / Double(s.total) : 0
    }

    private func updateBar() {
        bar.model.cpu = lastCPU
        bar.model.mem = lastMem
        bar.model.disk = lastSpace
        bar.model.io = lastIO
        bar.model.net = lastNet
        bar.needsDisplay = true
    }

    // MARK: 菜单

    private func infoItem(_ v: NSView) -> NSMenuItem {
        let i = NSMenuItem()
        i.view = v
        return i
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        for v in [cpuRow, cpuSplitRow, loadRow] { menu.addItem(infoItem(v)) }
        menu.addItem(.separator())
        for v in [memRow, pressureRow, appMemRow, wiredRow, compRow, cachedRow, swapRow] { menu.addItem(infoItem(v)) }
        menu.addItem(.separator())
        for v in [diskRow, diskFreeRow, diskIORow] { menu.addItem(infoItem(v)) }
        menu.addItem(.separator())
        for v in [netRow, netDownRow, netUpRow] { menu.addItem(infoItem(v)) }
        menu.addItem(.separator())

        memTopHeader.set("内存占用最多（我的进程）", "")
        menu.addItem(infoItem(memTopHeader))
        for _ in 0..<6 { let v = RowView(); let i = infoItem(v); memTopItems.append((i, v)); menu.addItem(i) }
        cpuTopHeader.set("CPU 占用最多（我的进程）", "")
        menu.addItem(infoItem(cpuTopHeader))
        for _ in 0..<5 { let v = RowView(); let i = infoItem(v); cpuTopItems.append((i, v)); menu.addItem(i) }
        menu.addItem(.separator())

        // 状态栏显示哪些
        let showMenu = NSMenu()
        for (idx, title) in ["CPU", "内存", "硬盘", "网络", "最吃内存的 App（详细样式）"].enumerated() {
            let i = NSMenuItem(title: title, action: #selector(toggleShow(_:)), keyEquivalent: "")
            i.target = self
            i.tag = idx
            showItems.append(i)
            showMenu.addItem(i)
        }
        let showRoot = NSMenuItem(title: "状态栏显示", action: nil, keyEquivalent: "")
        showRoot.submenu = showMenu
        menu.addItem(showRoot)

        // 样式：详细（加长）/ 紧凑（只用内建刘海屏时空间不够可切换）
        let styleMenu = NSMenu()
        for (key, title) in [("detailed", "详细（加长）"), ("compact", "紧凑")] {
            let i = NSMenuItem(title: title, action: #selector(setStyle(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = key
            styleItems.append(i)
            styleMenu.addItem(i)
        }
        let styleRoot = NSMenuItem(title: "状态栏样式", action: nil, keyEquivalent: "")
        styleRoot.submenu = styleMenu
        menu.addItem(styleRoot)

        // 刷新间隔
        let ivMenu = NSMenu()
        for sec in [1, 2, 3] {
            let i = NSMenuItem(title: "\(sec) 秒", action: #selector(setInterval(_:)), keyEquivalent: "")
            i.target = self
            i.tag = sec
            intervalItems.append(i)
            ivMenu.addItem(i)
        }
        let ivRoot = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        ivRoot.submenu = ivMenu
        menu.addItem(ivRoot)

        loginItem.target = self
        menu.addItem(loginItem)

        let am = NSMenuItem(title: "打开活动监视器", action: #selector(openActivityMonitor(_:)), keyEquivalent: "")
        am.target = self
        menu.addItem(am)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 BarMeter", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        refreshSettingStates()
    }

    private func refreshSettingStates() {
        for i in showItems { i.state = defaults.bool(forKey: Self.showKeys[i.tag]) ? .on : .off }
        let style = defaults.string(forKey: "style") ?? "detailed"
        for i in styleItems { i.state = (i.representedObject as? String) == style ? .on : .off }
        let iv = Int(interval)
        for i in intervalItems { i.state = i.tag == iv ? .on : .off }
        loginItem.state = LoginItem.isOn ? .on : .off
    }

    private func updateMenu() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if let c = lastCPU {
            cpuRow.set("CPU（\(cores) 核）", Fmt.pct(c.total), color: levelColor(cpuLevel(c.total)))
            cpuSplitRow.set("用户 / 系统", "\(Fmt.pct(c.user)) / \(Fmt.pct(c.system))")
        } else {
            cpuRow.set("CPU（\(cores) 核）", "--")
        }
        var la = [Double](repeating: 0, count: 3)
        if getloadavg(&la, 3) == 3 {
            loadRow.set("平均负载 1 / 5 / 15 分钟", String(format: "%.2f  %.2f  %.2f", la[0], la[1], la[2]))
        }

        if let m = lastMem {
            memRow.set("内存  \(Fmt.mem(m.used)) / \(Fmt.mem(m.total))", Fmt.pct(m.usedFraction), color: levelColor(m.pressure))
            let p: (String, NSColor) = {
                switch m.pressure {
                case .normal: return ("正常", NSColor.systemGreen)
                case .warn: return ("偏高", NSColor.systemOrange)
                case .critical: return ("紧张", NSColor.systemRed)
                }
            }()
            pressureRow.set("内存压力", p.0, color: p.1)
            appMemRow.set("App 内存", Fmt.mem(m.app))
            wiredRow.set("联动内存", Fmt.mem(m.wired))
            compRow.set("被压缩", Fmt.mem(m.compressed))
            cachedRow.set("已缓存文件", Fmt.mem(m.cached))
            swapRow.set("已使用的交换", Fmt.mem(m.swapUsed), color: m.swapUsed > 2 * 1_073_741_824 ? .systemOrange : .labelColor)
        }

        if let s = lastSpace {
            let u = diskUsed(s)
            let used = Double(s.total - min(s.free, s.total))
            diskRow.set("硬盘  已用 \(Fmt.bytes(used)) / \(Fmt.bytes(Double(s.total)))", Fmt.pct(u), color: levelColor(diskLevel(u)))
            diskFreeRow.set("实际可用（不含可清除）", Fmt.bytes(Double(s.free)))
        }
        if let io = lastIO {
            diskIORow.set("读取 / 写入", "\(Fmt.rate(io.read)) / \(Fmt.rate(io.write))")
        } else {
            diskIORow.set("读取 / 写入", "统计中…")
        }

        netRow.set("网络", "")
        if let n = lastNet {
            netDownRow.set("下载 ↓", Fmt.rate(n.down))
            netUpRow.set("上传 ↑", Fmt.rate(n.up))
        } else {
            netDownRow.set("下载 ↓", "--")
            netUpRow.set("上传 ↑", "--")
        }
    }

    /// 行数固定不增减，菜单打开时高度不会跳
    private func refreshTop(now: UInt64) {
        guard let r = procMeter.sample(now: now) else { return }
        for (idx, (_, row)) in memTopItems.enumerated() {
            if idx < r.mem.count {
                let g = r.mem[idx]
                row.set(g.count > 1 ? "\(g.name)（\(g.count)）" : g.name, Fmt.mem(g.footprint))
            } else {
                row.set("", "")
            }
        }
        for (idx, (_, row)) in cpuTopItems.enumerated() {
            if let cpu = r.cpu {
                if idx < cpu.count {
                    let g = cpu[idx]
                    row.set(g.count > 1 ? "\(g.name)（\(g.count)）" : g.name, String(format: "%.1f%%", g.cpu * 100))
                } else {
                    row.set("", "")
                }
            } else {
                row.set(idx == 0 ? "统计中…" : "", "")
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = true
        refreshSettingStates()
        let now = nowNs()
        procMeter.reset()
        refreshTop(now: now)                  // 内存排行立即可见
        updateMenu()
        // 1 秒后补采一次，让 CPU 排行和磁盘读写尽快出来
        quickTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(quickRefresh), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        quickTimer = t
    }

    @objc private func quickRefresh() {
        guard menuOpen else { return }
        let now = nowNs()
        refreshTop(now: now)
        updateMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = false
        quickTimer?.invalidate()
        quickTimer = nil
        procMeter.reset()        // 释放进程快照
    }

    // MARK: 设置

    private func applyVisibility() {
        bar.showCPU = defaults.bool(forKey: "showCPU")
        bar.showMem = defaults.bool(forKey: "showMem")
        bar.showDisk = defaults.bool(forKey: "showDisk")
        bar.showNet = defaults.bool(forKey: "showNet")
        bar.showTop = defaults.bool(forKey: "showTop")
        bar.detailed = (defaults.string(forKey: "style") ?? "detailed") != "compact"
        let w = bar.preferredWidth
        statusItem.length = w
        let h = statusItem.button?.bounds.height ?? 0
        bar.frame = NSRect(x: 0, y: 0, width: w, height: h > 0 ? h : NSStatusBar.system.thickness)
        bar.needsDisplay = true
    }

    @objc private func toggleShow(_ sender: NSMenuItem) {
        let key = Self.showKeys[sender.tag]
        let newValue = !defaults.bool(forKey: key)
        // 至少保留 CPU / 内存 / 硬盘 / 网络 中的一项
        let main4 = Array(Self.showKeys.prefix(4))
        let othersOn = main4.filter { $0 != key }.contains { defaults.bool(forKey: $0) }
        if main4.contains(key) && !newValue && !othersOn { NSSound.beep(); return }
        defaults.set(newValue, forKey: key)
        applyVisibility()
        refreshSettingStates()
    }

    @objc private func setStyle(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(key, forKey: "style")
        applyVisibility()
        refreshSettingStates()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        defaults.set(Double(sender.tag), forKey: "interval")
        startTimer()
        refreshSettingStates()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let ok = LoginItem.set(!LoginItem.isOn)
        if !ok { NSSound.beep() }
        refreshSettingStates()
    }

    @objc private func openActivityMonitor(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
