import Foundation
import Postbox

public enum AyuArchiveReason: Int32 {
    /// The message was removed from the chat (by anyone, including the user).
    case deleted = 0
    /// A previous revision kept because the message was edited.
    case edited = 1
}

/// A message kept after Telegram dropped it.
///
/// Media and attributes are stored as Postbox objects rather than a flattened
/// description, so an archived message can be rendered with the same nodes as
/// a live one and cached media keeps resolving through the existing MediaBox.
public final class AyuArchivedMessage {
    public let id: MessageId
    public let authorId: PeerId?
    /// When the message was originally sent.
    public let timestamp: Int32
    /// When it was deleted or superseded.
    public let archivedTimestamp: Int32
    public let flags: MessageFlags
    public let text: String
    public let media: [Media]
    public let attributes: [MessageAttribute]
    public let reason: AyuArchiveReason
    /// 0 for the original text, incrementing for each kept edit.
    public let revision: Int32

    public init(
        id: MessageId,
        authorId: PeerId?,
        timestamp: Int32,
        archivedTimestamp: Int32,
        flags: MessageFlags,
        text: String,
        media: [Media],
        attributes: [MessageAttribute],
        reason: AyuArchiveReason,
        revision: Int32
    ) {
        self.id = id
        self.authorId = authorId
        self.timestamp = timestamp
        self.archivedTimestamp = archivedTimestamp
        self.flags = flags
        self.text = text
        self.media = media
        self.attributes = attributes
        self.reason = reason
        self.revision = revision
    }

    public var isOutgoing: Bool {
        return !self.flags.contains(.Incoming)
    }
}

extension AyuArchivedMessage {
    func encoded() -> Data {
        let encoder = PostboxEncoder()
        encoder.encodeInt64(self.id.peerId.toInt64(), forKey: "p")
        encoder.encodeInt32(self.id.namespace, forKey: "n")
        encoder.encodeInt32(self.id.id, forKey: "i")
        if let authorId = self.authorId {
            encoder.encodeInt64(authorId.toInt64(), forKey: "a")
        }
        encoder.encodeInt32(self.timestamp, forKey: "t")
        encoder.encodeInt32(self.archivedTimestamp, forKey: "d")
        encoder.encodeInt32(Int32(bitPattern: self.flags.rawValue), forKey: "f")
        encoder.encodeString(self.text, forKey: "s")
        encoder.encodeGenericObjectArray(self.media.compactMap { $0 as? PostboxCoding }, forKey: "m")
        encoder.encodeGenericObjectArray(self.attributes.compactMap { $0 as? PostboxCoding }, forKey: "r")
        encoder.encodeInt32(self.reason.rawValue, forKey: "w")
        encoder.encodeInt32(self.revision, forKey: "v")
        return encoder.makeData()
    }

    static func decoded(from data: Data) -> AyuArchivedMessage? {
        let decoder = PostboxDecoder(buffer: MemoryBuffer(data: data))
        guard let peerIdValue = decoder.decodeOptionalInt64ForKey("p"),
              let namespace = decoder.decodeOptionalInt32ForKey("n"),
              let idValue = decoder.decodeOptionalInt32ForKey("i"),
              let timestamp = decoder.decodeOptionalInt32ForKey("t")
        else {
            return nil
        }
        let peerId = PeerId(peerIdValue)
        let media = (decoder.decodeObjectArrayForKey("m") as [PostboxCoding]).compactMap { $0 as? Media }
        let attributes = (decoder.decodeObjectArrayForKey("r") as [PostboxCoding]).compactMap { $0 as? MessageAttribute }
        return AyuArchivedMessage(
            id: MessageId(peerId: peerId, namespace: namespace, id: idValue),
            authorId: decoder.decodeOptionalInt64ForKey("a").flatMap(PeerId.init),
            timestamp: timestamp,
            archivedTimestamp: decoder.decodeInt32ForKey("d", orElse: timestamp),
            flags: MessageFlags(rawValue: UInt32(bitPattern: decoder.decodeInt32ForKey("f", orElse: 0))),
            text: decoder.decodeStringForKey("s", orElse: ""),
            media: media,
            attributes: attributes,
            reason: AyuArchiveReason(rawValue: decoder.decodeInt32ForKey("w", orElse: 0)) ?? .deleted,
            revision: decoder.decodeInt32ForKey("v", orElse: 0)
        )
    }
}
