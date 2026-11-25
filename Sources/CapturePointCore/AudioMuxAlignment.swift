import Foundation

/// Aligns the Core Audio process tap with `screencapture` video.
///
/// The tap starts before the window/selection picker; both stop together.
/// Extra audio at the front is pre-roll. A short tail is subtracted because
/// the tap is stopped after `screencapture` exits.
public enum AudioMuxAlignment {
    public static let tapStopTail: TimeInterval = 0.06
    public static let clockHintSlack: TimeInterval = 0.04
    public static let minimumUsableAudio: TimeInterval = 0.05

    public static func hintedLead(audioStarted: Date, videoStarted: Date) -> TimeInterval {
        max(0, videoStarted.timeIntervalSince(audioStarted) - clockHintSlack)
    }

    public static func lead(
        audioDuration: TimeInterval,
        videoDuration: TimeInterval,
        hintedLead: TimeInterval
    ) -> TimeInterval {
        // The tap starts first and both stop together, so leftover audio
        // at the front is preroll. A file-watch timeout can report ~180s of
        // "lead" even when the two files only differ by a second.
        let fromDurations = max(0, audioDuration - videoDuration - tapStopTail)
        if hintedLead > 0, hintedLead < fromDurations {
            return hintedLead
        }
        return fromDurations
    }

    public static func usableAudioRange(
        audioDuration: TimeInterval,
        videoDuration: TimeInterval,
        lead: TimeInterval
    ) -> (start: TimeInterval, duration: TimeInterval)? {
        let remaining = audioDuration - lead
        let use = min(videoDuration, remaining)
        guard remaining.isFinite, use > minimumUsableAudio else { return nil }
        return (lead, use)
    }
}
