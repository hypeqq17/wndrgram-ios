import Foundation

/// Seam that lets a higher layer inspect messages just before Postbox drops
/// them, without Postbox itself gaining a dependency on that layer.
///
/// The closure runs **inside** the deleting transaction and on the Postbox
/// queue, so it may read from the passed `Transaction` but must not start
/// asynchronous work that touches Postbox again. Keep it fast: it is on the
/// path of every deletion, including bulk server-side ones.
public enum PostboxMessageDeletionHook {
    /// Installed once at account setup; `nil` means no observer and costs
    /// nothing beyond an optional check.
    public static var willDelete: ((Transaction, [MessageId]) -> Void)?

    /// Runs after `willDelete` and returns the subset that is actually removed.
    /// An observer can keep a message in the history by leaving its id out —
    /// it must then mark that message itself, or the next deletion pass will
    /// ask about it again forever.
    public static var filterDeletions: ((Transaction, [MessageId]) -> [MessageId])?

    /// Called with the message as it exists *before* an update is applied and
    /// with the update that is about to replace it, so an observer can keep the
    /// previous revision. Same threading rules as `willDelete`.
    public static var willUpdate: ((Transaction, Message, PostboxUpdateMessage) -> Void)?

    /// Lets an observer rewrite an update before it is applied (for example to
    /// keep media that is about to be replaced). Runs before `willUpdate`.
    public static var transformUpdate: ((Transaction, Message, PostboxUpdateMessage) -> PostboxUpdateMessage)?
}
