#if os(macOS)
import Foundation
import Darwin

/// Process-level resource sampling. GPU utilisation is not exposed by public macOS APIs,
/// so we report measured GPU render time per frame from Metal command buffers instead.
public struct PerformanceSnapshot: Equatable, Sendable {
    public var cpuPercent: Double          // of one core (100 = one core fully busy)
    public var cpuPercentOfMachine: Double // normalised by active processor count
    public var memoryMB: Double            // phys_footprint, same figure as Activity Monitor "Memory"
    public var gpuFrameMs: Double          // average GPU time per composited frame
    public var renderFPS: Double
    public var droppedRenderFrames: UInt64
    public var thermalState: ProcessInfo.ThermalState

    public static let zero = PerformanceSnapshot(cpuPercent: 0, cpuPercentOfMachine: 0, memoryMB: 0, gpuFrameMs: 0,
                                                 renderFPS: 0, droppedRenderFrames: 0, thermalState: .nominal)
}

public final class PerformanceMonitor {
    private var lastCPUTime: Double = 0
    private var lastWall: Double = 0

    public init() {
        lastCPUTime = Self.processCPUSeconds()
        lastWall = ProcessInfo.processInfo.systemUptime
    }

    /// Call ~1 Hz from the main thread.
    public func sample(gpuFrameMs: Double, renderFPS: Double, dropped: UInt64) -> PerformanceSnapshot {
        let cpu = Self.processCPUSeconds()
        let wall = ProcessInfo.processInfo.systemUptime
        let dt = max(wall - lastWall, 0.001)
        let pct = (cpu - lastCPUTime) / dt * 100
        lastCPUTime = cpu; lastWall = wall
        let cores = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        return PerformanceSnapshot(cpuPercent: pct, cpuPercentOfMachine: pct / cores, memoryMB: Self.footprintMB(),
                                   gpuFrameMs: gpuFrameMs, renderFPS: renderFPS, droppedRenderFrames: dropped,
                                   thermalState: ProcessInfo.processInfo.thermalState)
    }

    static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return secs(usage.ru_utime) + secs(usage.ru_stime)
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
#endif
