import SwiftUI
import Darwin

@MainActor
final class ResourceMonitor: ObservableObject {
    @Published private(set) var cpu: Double?
    @Published private(set) var memory: UInt64?
    private var task: Task<Void, Never>?
    private var prior: (Double, TimeInterval)?
    struct BrowserUsage: Identifiable {
        let id: Int
        let name: String
        let memory: UInt64
        let cpu: Double?
    }
    @Published private(set) var browserUsage: [BrowserUsage] = []
    var rendererNames: (() -> [Int32: Set<String>])?
    private var processPrior: [Int: (start: Double, ticks: Double, wall: Double)] = [:]

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                await self?.sampleBrowser()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
    private func sampleBrowser() async {
        guard let names = rendererNames?(), !names.isEmpty,
              let data = await ChromiumRuntime.shared.processData(),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            if !browserUsage.isEmpty { browserUsage = [] }
            processPrior = [:]; return
        }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        let now = ProcessInfo.processInfo.systemUptime
        var next: [Int: (start: Double, ticks: Double, wall: Double)] = [:]
        var usage: [BrowserUsage] = []
        for row in rows {
            guard let pid = row["pid"] as? Int, pid != Int(getpid()), let start = row["start"] as? Double,
                  let ticks = row["timeTicks"] as? Double, let bytes = row["memory"] as? NSNumber else { continue }
            let previous = processPrior[pid]
            let cpu = previous.flatMap { old -> Double? in
                guard old.start == start, now > old.wall, ticks >= old.ticks else { return nil }
                return 100 * (ticks - old.ticks) * secondsPerTick / (now - old.wall)
            }
            next[pid] = (start, ticks, now)
            let owners = names[Int32(pid)] ?? []
            let name = owners.count == 1 ? owners.first! + " renderer" : owners.isEmpty ? "Shared process" : "Shared services"
            usage.append(BrowserUsage(id: pid, name: name, memory: bytes.uint64Value, cpu: cpu))
        }
        processPrior = next
        browserUsage = usage.sorted { $0.memory > $1.memory }
    }
    private func sample() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        memory = result == KERN_SUCCESS ? info.resident_size : nil
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { cpu = nil; return }
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = prior, now > previous.1 { cpu = max(0, 100 * (seconds - previous.0) / (now - previous.1)) }
        prior = (seconds, now)
    }
}

struct ResourcePulse: View {
    @ObservedObject var monitor: ResourceMonitor
    let theme: ShellTheme
    let compact: Bool
    @ViewState private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: "waveform.path.ecg").foregroundStyle(theme.muted)
                .frame(width: compact ? 30 : 46, height: compact ? 32 : 38)
        }.buttonStyle(ShellButtonStyle(theme: theme)).accessibilityLabel("Resource usage")
        .accessibilityValue("Relay shell: " + summary)
        .onHover { expanded = $0 }
        .popover(isPresented: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Relay shell").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(summary).font(.system(size: 12)).monospacedDigit()
                ForEach(monitor.browserUsage) { usage in
                    Divider()
                    Text(usage.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text("\(usage.cpu.map { String(format: "%.1f%% CPU", $0) } ?? "— CPU") · \(ByteCountFormatter.string(fromByteCount: Int64(usage.memory), countStyle: .memory)) RAM")
                        .font(.system(size: 12)).monospacedDigit()
                }
            }.padding(12).fixedSize()
        }
    }
    private var summary: String {
        let cpu = monitor.cpu.map { String(format: "%.1f%% CPU", $0) } ?? "— CPU"
        let ram = monitor.memory.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) + " RAM" } ?? "— RAM"
        return "\(cpu) · \(ram)"
    }
}
