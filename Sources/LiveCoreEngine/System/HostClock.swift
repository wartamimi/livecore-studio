#if os(macOS)
import CoreMedia
import QuartzCore

/// Single time base for the whole pipeline: the host clock (mach_absolute_time), exposed as
/// seconds via CACurrentMediaTime and as CMTime via CMClockGetHostTimeClock. Video frames,
/// captured audio and the mixer's render timestamps are all expressed in this clock, which is
/// what keeps audio and video aligned in the encoders.
public enum HostClock {
    @inline(__always) public static func now() -> Double { CACurrentMediaTime() }
    @inline(__always) public static func nowCMTime() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
    public static func seconds(fromHostTicks ticks: UInt64) -> Double {
        CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(ticks))
    }
}
#endif
