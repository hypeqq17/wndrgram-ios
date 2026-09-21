import Foundation
import Postbox

/// Marks a message that Telegram deleted but AyuGram kept in the local history.
///
/// Its presence is also the guard that makes the retention idempotent: a
/// message that already carries it is never retained again, so the user can
/// still delete it for good from their own device.
public class AyuDeletedMessageAttribute: MessageAttribute {
    /// When the deletion arrived.
    public let timestamp: Int32

    public init(timestamp: Int32) {
        self.timestamp = timestamp
    }

    required public init(decoder: PostboxDecoder) {
        self.timestamp = decoder.decodeInt32ForKey("t", orElse: 0)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.timestamp, forKey: "t")
    }
}

public extension Message {
    /// Non-nil when this message only survives because AyuGram kept it.
    var ayuDeletedAttribute: AyuDeletedMessageAttribute? {
        for attribute in self.attributes {
            if let attribute = attribute as? AyuDeletedMessageAttribute {
                return attribute
            }
        }
        return nil
    }

    var isAyuDeleted: Bool {
        return self.ayuDeletedAttribute != nil
    }
}
