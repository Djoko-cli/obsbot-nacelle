import CoreMedia
import Darwin

/// L'horloge de l'hôte (celle de `CMClockGetHostTimeClock`, qui compte les mêmes ticks que
/// `mach_absolute_time`), en nanosecondes. Vidéo et son sont horodatés sur elle à leur arrivée (spec
/// enregistrement § 4.1). Lecture sans verrou ni allocation : elle sert aussi sur le fil audio temps réel.
enum HostClock {
    static func nowNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    static func time(nanoseconds: UInt64) -> CMTime {
        CMTime(value: CMTimeValue(nanoseconds), timescale: 1_000_000_000)
    }
}
