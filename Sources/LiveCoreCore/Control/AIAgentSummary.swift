/// Event summary from the transcript (0.71.0): the Transcript window hands the text to the AI
/// Assistant with one of these instructions; the answer appears in the assistant's chat.
extension AIAgent {
    public enum SummaryKind: String, CaseIterable, Sendable {
        case summary, minutes, chapters
    }

    /// Transcripts longer than this keep their beginning and end (the middle is cut), so the
    /// request stays inside every provider's free-tier limits.
    public static let summaryMaxCharacters = 60_000

    public static func clippedTranscript(_ t: String, max: Int = summaryMaxCharacters) -> String {
        guard t.count > max, max > 200 else { return t }
        let head = t.prefix(max * 2 / 3), tail = t.suffix(max / 3 - 40)
        return head + "\n[… middle of the transcript left out …]\n" + tail
    }

    public static func summaryCommand(_ kind: SummaryKind, transcript: String) -> String {
        let task: String
        switch kind {
        case .summary:
            task = "Write a short summary of this event (5 to 8 sentences), then the key points as a list."
        case .minutes:
            task = "Write meeting minutes: topics discussed, decisions, action items with who is responsible (when said), and open questions."
        case .chapters:
            task = "Write YouTube chapters: one line per topic change, \"HH:MM:SS Title\", the first one at 00:00:00. The transcript's times are clock times: count from the first line's time. Titles of at most 6 words."
        }
        return """
        \(task) Answer in the language of the transcript. Do not use any tools and do not change anything in the show; only write the text.

        Transcript:
        \(clippedTranscript(transcript))
        """
    }
}
