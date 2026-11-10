import AppKit
import Darwin

public extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Stable across reconnects, unlike `CGDirectDisplayID`.
    var displayUUID: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return String(displayID)
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

public enum ProcessMemory {
    /// The figure Activity Monitor shows in its Memory column.
    public static func footprint(pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    // Private but long-stable libsystem call. If it ever disappears the row just reads zero.
    private static let responsiblePID: ResponsiblePID? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: ResponsiblePID.self) }

    /// Memory held by the macOS video decoder processes working on behalf of `pid`. They hold the
    /// decoded frames, which is most of a video wallpaper's real cost, and appear separately in
    /// Activity Monitor as VTDecoderXPCService.
    public static func decoderFootprint(for pid: pid_t) -> UInt64 {
        guard let responsiblePID else { return 0 }
        var candidates = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&candidates, Int32(candidates.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return 0 }

        var total: UInt64 = 0
        var name = [CChar](repeating: 0, count: 64)
        for candidate in candidates.prefix(count) where candidate > 0 {
            guard proc_name(candidate, &name, UInt32(name.count)) > 0,
                  String(cString: name) == "VTDecoderXPCService",
                  responsiblePID(candidate) == pid else { continue }
            total += footprint(pid: candidate) ?? 0
        }
        return total
    }
}
