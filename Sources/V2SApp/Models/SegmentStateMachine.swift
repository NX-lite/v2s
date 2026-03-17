import Foundation

/// Per-segment lifecycle state, from first partial ASR token to archived.
enum SegmentState: Equatable, Sendable {
    /// Waiting — no audio detected yet for this segment.
    case listening

    /// Partial ASR tokens are arriving; draft layer is showing.
    case draftingSource

    /// ChunkScore is in the 0.60–0.72 range; observation window started.
    case commitCandidate

    /// Chunk committed; source text is final and displayed.
    case committedSource

    /// Translation received and displayed.
    case committedTranslation

    /// One light post-edit allowed within the revision window.
    case softPostEdit

    /// Caption is fading out (previous-caption layer).
    case fadeHold

    /// Caption retired to history; no longer visible.
    case archived
}
