//
//  MessageDb.swift
//  ios
//
//  Copyright © 2019 Tinode. All rights reserved.
//

import Foundation
import SQLite
import TinodeSDK

enum MessageDbError: Error {
    case dataError(String)
    case dbError(String)
}

// The table contains:
// * messages (both synchronized and not yet synchronized with the server).
// * message deletion markers (synchronized and not yet synchronized).
public class MessageDb {
    public static let kTableName = "messages"
    public static let kMessagePreviewLength = 80
    private let db: SQLite.Connection

    public var table: Table

    public let id: Expression<Int64>
    // Topic ID, references topics.id
    public let topicId: Expression<Int64?>
    // Id of the originator of the message, references users.id
    public let userId: Expression<Int64?>
    public let status: Expression<Int?>
    public let sender: Expression<String?>
    public let ts: Expression<Date?>
    public let seq: Expression<Int?>
    public let high: Expression<Int?>
    public let delId: Expression<Int?>
    // Seq id this message replaces (on the same topic).
    public let replacesSeq: Expression<Int?>
    // Seq id of the message that replaces this message (on the same topic).
    public let replacedBySeq: Expression<Int?>
    public let head: Expression<String?>
    public let content: Expression<String?>

    private let baseDb: BaseDb!

    init(_ database: SQLite.Connection, baseDb: BaseDb) {
        self.db = database
        self.baseDb = baseDb
        self.table = Table(MessageDb.kTableName)
        self.id = Expression<Int64>("id")
        self.topicId = Expression<Int64?>("topic_id")
        self.userId = Expression<Int64?>("user_id")
        self.status = Expression<Int?>("status")
        self.sender = Expression<String?>("sender")
        self.ts = Expression<Date?>("ts")
        self.seq = Expression<Int?>("seq")
        self.high = Expression<Int?>("high")
        self.delId = Expression<Int?>("del_id")
        self.replacesSeq = Expression<Int?>("replaces_seq")
        self.replacedBySeq = Expression<Int?>("replaced_by_seq")
        self.head = Expression<String?>("head")
        self.content = Expression<String?>("content")
    }
    func destroyTable() {
        try! self.db.run(self.table.dropIndex(topicId, seq.desc, ifExists: true))
        try! self.db.run(self.table.drop(ifExists: true))
    }
    func createTable() {
        let userDb = baseDb.userDb!
        let topicDb = baseDb.topicDb!
        // Must succeed.
        try! self.db.run(self.table.create(ifNotExists: true) { t in
            t.column(id, primaryKey: .autoincrement)
            t.column(topicId, references: topicDb.table, topicDb.id)
            t.column(userId, references: userDb.table, userDb.id)
            t.column(status)
            t.column(sender)
            t.column(ts)
            t.column(seq)
            t.column(high)
            t.column(delId)
            t.column(replacesSeq)
            t.column(replacedBySeq)
            t.column(head)
            t.column(content)
        })
        try! self.db.run(self.table.createIndex(topicId, seq.desc, unique: true, ifNotExists: true))
    }

    private func replaceMessage(onTopic topicId: Int64, withSeqId seqId: Int, forReplacingSeqId replacingSeqId: Int) throws {
        let record = self.table.filter(self.topicId == topicId &&
                                       self.seq == seqId &&
                                       (self.replacedBySeq == nil || self.replacedBySeq < replacingSeqId))
        try self.db.run(record.update(self.replacedBySeq <- replacingSeqId))
    }

    private func maybeUpdateReplaced(withId msgId: Int64, onTopic topicId: Int64, withSeqId seqId: Int) throws {
        let replQuery = self.table
            .filter(self.table[self.topicId] == topicId &&
                    self.table[self.replacesSeq] == seqId)

        guard let replacedBySeq = try? db.scalar(replQuery.select(self.table[self.seq].max)) else {
            // No replacements for this message. We are done.
            return
        }

        let record = self.table.filter(self.id == msgId)
        try self.db.run(record.update(self.replacedBySeq <- replacedBySeq))
    }

    @discardableResult
    private func insertRaw(topic: TopicProto, msg: StoredMessage) throws -> Int64 {
        do {
            guard let tdb = baseDb.topicDb else {
                throw MessageDbError.dbError("no topicDb in messageDb insert")
            }
            if (msg.topicId ?? -1) <= 0 {
                msg.topicId = tdb.getId(topic: msg.topic)
            }
            guard let udb = baseDb.userDb else {
                throw MessageDbError.dbError("no userDb in messageDb insert")
            }
            if (msg.userId ?? -1) <= 0 {
                msg.userId = udb.getId(for: msg.from)
            }
            guard let topicId = msg.topicId, let userId = msg.userId, topicId >= 0, userId >= 0 else {
                throw MessageDbError.dataError("Failed to insert row into MessageDb: topicId = \(String(describing: msg.topicId)), userId = \(String(describing: msg.userId))")
            }
            var status = BaseDb.Status.undefined
            if let seq = msg.seq, seq > 0 {
                status = .synced
            } else {
                msg.seq = tdb.getNextUnusedSeq(topic: topic)
                status = (msg.dbStatus == nil || msg.dbStatus == BaseDb.Status.undefined) ? .queued : msg.dbStatus!
            }
            var setters = [Setter]()
            setters.append(self.topicId <- topicId)
            setters.append(self.userId <- userId)
            setters.append(self.status <- status.rawValue)
            setters.append(self.sender <- msg.from)
            setters.append(self.ts <- msg.ts)
            setters.append(self.seq <- msg.seq)
            if let replaced = msg.replacesSeq {
                setters.append(self.replacesSeq <- replaced)
            }
            if let h = msg.head {
                setters.append(self.head <- Tinode.serializeObject(h))
            }
            setters.append(self.content <- msg.content?.serialize())
            msg.msgId = try db.run(self.table.insert(setters))
            return msg.msgId
        } catch {
            BaseDb.log.error("MessageDb - insertRaw failed")
            throw MessageDbError.dbError("Insertion failed - \(error)")
        }
    }

    func insert(topic: TopicProto?, msg: StoredMessage?) -> Int64 {
        guard let topic = topic, let msg = msg else {
            return -1
        }
        if msg.msgId > 0 {
            // Already saved.
            return msg.msgId
        }
        do {
            try db.savepoint("MessageDb.insert") {
                let insertedId = try insertRaw(topic: topic, msg: msg)
                if let replacedSeq = msg.replacesSeq, replacedSeq > 0 {
                    // Replacement message.
                    try replaceMessage(onTopic: msg.topicId!, withSeqId: replacedSeq, forReplacingSeqId: msg.seq!)
                } else {
                    // This is the original message.
                    // Check if it's been replaced.
                    try maybeUpdateReplaced(withId: insertedId, onTopic: msg.topicId!, withSeqId: msg.seq!)
                }
            }
            return msg.msgId
        } catch {
            BaseDb.log.error("MessageDb - insert operation failed: %@", error.localizedDescription)
            return -1
        }
    }

    func updateStatusAndContent(msgId: Int64, status: BaseDb.Status?, content: Drafty?) -> Bool {
        let record = self.table.filter(self.id == msgId)
        var setters = [Setter]()
        if status != .undefined {
            setters.append(self.status <- status!.rawValue)
        }
        if content != nil {
            setters.append(self.content <- content!.serialize())
        }
        if !setters.isEmpty {
            do {
                return try self.db.run(record.update(setters)) > 0
            } catch {
                BaseDb.log.error("MessageDb - update status operation failed: msgId = %lld, error = %@", msgId, error.localizedDescription)
            }
        }
        return false
    }

    func delivered(msgId: Int64, ts: Date?, seq: Int?) -> Bool {
        let record = self.table.filter(self.id == msgId)
        do {
            return try self.db.run(record.update(self.status <- BaseDb.Status.synced.rawValue, self.ts <- ts, self.seq <- seq)) > 0
        } catch {
            BaseDb.log.error("MessageDb - update delivery operation failed: msgId = %lld, error = %@", msgId, error.localizedDescription)
            return false
        }
    }

    // Deletes all messages in a given topic, no exceptions. Use only when deleting the topic.
    @discardableResult
    func deleteAll(forTopic topicId: Int64) -> Bool {
        // Delete from messages where topic_id = topicId.
        let rows = self.table.filter(self.topicId == topicId)
        do {
            return try self.db.run(rows.delete()) > 0
        } catch {
            BaseDb.log.error("MessageDb - deleteAll(forTopic) operation failed: topicId = %lld, error = %@", topicId, error.localizedDescription)
            return false
        }
    }

    /// Delete failed messages in a given topic.
    /// - Parameters:
    ///  - topicId Tinode topic ID to delete messages from.
    /// - Returns `true` if any messages were deleted.
    @discardableResult
    func deleteFailed(forTopic topicId: Int64) -> Bool {
        let rows = self.table.filter(self.topicId == topicId && self.status == BaseDb.Status.failed.rawValue)
        do {
            return try self.db.run(rows.delete()) > 0
        } catch {
            BaseDb.log.error("MessageDb - deleteFailed(forTopic) operation failed: topicId = %lld, error = %@", topicId, error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func delete(topicId: Int64, deleteId delId: Int?, from loId: Int, to hiId: Int?) -> Bool {
        return deleteOrMarkDeleted(topicId: topicId, delId: delId, from: loId, to: hiId, hard: false)
    }

    @discardableResult
    func deleteOrMarkDeleted(topicId: Int64, delId: Int?, inRanges ranges: [MsgRange], hard: Bool) -> Bool {
        var success = false
        do {
            try db.savepoint("MessageDb.deleteOrMarkDeleted-ranges") {
                for r in ranges {
                    if !deleteOrMarkDeleted(topicId: topicId, delId: delId, from: r.lower, to: r.upper, hard: hard) {
                        throw MessageDbError.dbError("Failed to process: delId \(delId ?? -1) range: \(r)")
                    }
                }
            }
            success = true
        } catch {
            BaseDb.log.error("MessageDb - deleteOrMarkDeleted2 with ranges failed: topicId = %lld, error = %@", topicId, error.localizedDescription)
        }
        return success
    }
    @discardableResult
    func deleteOrMarkDeleted(topicId: Int64, delId: Int?, from loId: Int, to hiId: Int?, hard: Bool) -> Bool {
        let delId = delId ?? 0
        var startId = loId
        var endId = hiId ?? Int.max
        if endId == 0 {
            endId = startId + 1
        }
        // 1. Delete all messages in the range.
        do {
            var updateResult = false
            try db.savepoint("MessageDb.deleteOrMarkDeleted-plain") {
                // Message selector: all messages in a given topic with seq between fromId and toId [inclusive, exclusive).
                let messageSelector = self.table.filter(
                    self.topicId == topicId && startId <= self.seq && self.seq < endId && self.status <= BaseDb.Status.synced.rawValue)
                // Selector of ranges which are fully within the new range.
                let rangeDeleteSelector = self.table.filter(
                    self.topicId == topicId && startId <= self.seq && self.seq < endId && self.status >= BaseDb.Status.deletedHard.rawValue)

                // Selector of partially overlapping deletion ranges. Find bounds of existing deletion ranges of the same type
                // which partially overlap with the new deletion range.
                let statusToConsume =
                    delId > 0 ? BaseDb.Status.deletedSynced :
                    hard ? BaseDb.Status.deletedHard : BaseDb.Status.deletedSoft
                var rangeConsumeSelector = self.table.filter(
                    self.topicId == topicId && self.status == statusToConsume.rawValue
                )
                if delId > 0 {
                    rangeConsumeSelector = rangeConsumeSelector.filter(self.delId < delId)
                }

                let overlapSelector = rangeConsumeSelector.filter(
                    self.high >= startId && self.seq <= endId
                )

                try self.db.run(messageSelector.delete())
                try self.db.run(rangeDeleteSelector.delete())

                // Find the maximum continuous range which overlaps with the current range.
                let fullRange = overlapSelector.select([self.seq.min, self.high.max])
                if let row = try? db.pluck(fullRange) {
                    if let newStartId = row[self.seq.min], newStartId < startId {
                        startId = newStartId
                    }
                    if let newEndId = row[self.high.max], newEndId > endId {
                        endId = newEndId
                    }
                }

                // 3. Consume partially overlapped ranges. They will be replaced with the new expanded range.
                let overlapSelector2 = rangeConsumeSelector.filter(
                    self.high >= startId && self.seq <= endId
                )
                try self.db.run(overlapSelector2.delete())

                // 4. Insert new range.
                var setters = [Setter]()
                setters.append(self.topicId <- topicId)
                setters.append(self.delId <- delId)
                setters.append(self.seq <- startId)
                setters.append(self.high <- endId)
                setters.append(self.status <- statusToConsume.rawValue)
                updateResult = try db.run(self.table.insert(setters)) > 0
            }
            return updateResult
        } catch {
            BaseDb.log.error("MessageDb - markDeleted operation failed: topicId = %lld, error = %@", topicId, error.localizedDescription)
            return false
        }
    }
    func delete(msgId: Int64) -> Bool {
        let record = self.table.filter(self.id == msgId)
        do {
            return try self.db.run(record.delete()) > 0
        } catch {
            BaseDb.log.error("MessageDb - delete operation failed: msgId = %lld, error = %@", msgId, error.localizedDescription)
            return false
        }
    }
    private func readOne(r: Row, previewLen: Int = -1) -> StoredMessage {
        let sm = StoredMessage()
        sm.msgId = r[self.table[self.id]]
        sm.topicId = r[self.table[self.topicId]]
        sm.userId = r[self.table[self.userId]]
        sm.dbStatus = BaseDb.Status(rawValue: r[self.table[self.status]] ?? 0) ?? .undefined
        sm.from = r[self.table[self.sender]]
        sm.ts = r[self.table[self.ts]]
        sm.seq = r[self.table[self.seq]]
        sm.head = Tinode.deserializeObject(from: r[self.table[self.head]])
        sm.content = Drafty.deserialize(from: r[self.table[self.content]])
        if previewLen > 0, let content = sm.content {
            sm.content = content.preview(previewLen: previewLen)
        }
        return sm
    }

    /// Load messages from `topicId` stating with seq `from` (exclusive) and returning no more than `limit`.
    /// If `forward` is `true`, load newer messages, older otherwise.
    func query(topicId: Int64?, from: Int, limit: Int, forward: Bool) -> [StoredMessage]? {
        guard let topicId = topicId else { return nil }

        let messages2 = self.table.alias("m2")
        var query = self.table
            .join(.leftOuter, messages2,
                  on: self.table[self.topicId] == messages2[self.topicId] &&
                        self.table[self.replacedBySeq] == messages2[self.seq])
        query = forward ?
            query.filter(self.table[self.topicId] == topicId && self.table[self.seq] > from && self.table[self.replacesSeq] == nil) :
            query.filter(self.table[self.topicId] == topicId && self.table[self.seq] < from && self.table[self.replacesSeq] == nil)
        query = (forward ? query.order(self.seq.asc) : query.order(self.seq.desc)).limit(limit)
            .select(self.table[*],
                    messages2[self.head],
                    messages2[self.content])

        do {
            var messages: [StoredMessage] = []
            for row in try db.prepare(query) {
                let sm = self.readOne(r: row)
                if let replacementHead = row[messages2[self.head]], let replacementContent = row[messages2[self.content]] {
                    sm.head = Tinode.deserializeObject(from: replacementHead)
                    sm.content = Drafty.deserialize(from: replacementContent)
                }
                messages.append(sm)
            }
            return messages
        } catch {
            BaseDb.log.error("MessageDb - query operation failed: topicId = %lld, error = %@", topicId, error.localizedDescription)
            return nil
        }
    }

    func query(msgId: Int64?, previewLen: Int) -> StoredMessage? {
        guard let msgId = msgId else { return nil }
        let record = self.table.filter(self.id == msgId).select(self.table[*])
        if let row = try? db.pluck(record) {
            return self.readOne(r: row, previewLen: previewLen)
        }
        return nil
    }

    func queryDeleted(topicId: Int64?, hard: Bool) -> [MsgRange]? {
        guard let topicId = topicId else { return nil }
        let status = hard ? BaseDb.Status.deletedHard : BaseDb.Status.deletedSoft
        let queryTable = self.table
            .filter(
                self.topicId == topicId &&
                    self.status == status.rawValue)
            .select(self.delId, self.seq, self.high)
            .order(self.seq)
        do {
            var ranges = [MsgRange]()
            for row in try db.prepare(queryTable) {
                if let low = row[self.seq] {
                    ranges.append(MsgRange(low: low, hi: row[self.high]))
                }
            }
            return ranges
        } catch {
            BaseDb.log.error("MessageDb - queryDeleted operation failed: topicId = %lld, error = %@", topicId, error.localizedDescription)
            return nil
        }
    }
    func queryUnsent(topicId: Int64?) -> [Message]? {
        let queryTable = self.table
            .filter(self.topicId == topicId && self.status == BaseDb.Status.queued.rawValue)
            .select(self.table[*])
            .order(self.ts)
        do {
            var messages = [StoredMessage]()
            for row in try db.prepare(queryTable) {
                let sm = self.readOne(r: row)
                messages.append(sm)
            }
            return messages
        } catch {
            BaseDb.log.error("MessageDb - queryUnsent operation failed: topicId = %lld, error = %@", topicId ?? -1, error.localizedDescription)
            return nil
        }
    }

    /// Returns the newest message range (low + high seq ID values) not found in the cache.
    func fetchNextMissingRange(topicId: Int64) -> MsgRange? {
        let messages2 = self.table.alias("m2")
        let hiQuery = self.table
            .join(.leftOuter, messages2,
                  on: self.table[self.seq] == (messages2[self.high] ?? messages2[self.seq] + 1) && messages2[self.topicId] == topicId)
            .filter(self.table[self.topicId] == topicId &&
                    self.table[self.seq] > 1 &&
                    messages2[self.seq] == nil)

        guard let hi = try? db.scalar(hiQuery.select(self.table[self.seq].max)) else {
            // No gap is found.
            return nil
        }
        // Find the first present message with ID less than the 'hi'.
        let seqExpr = (self.high - 1) ?? self.seq
        let lowQuery = self.table
            .filter(self.topicId == topicId && self.seq < hi)
        let low: Int
        if let low2 = try? db.scalar(lowQuery.select(seqExpr.max)) {
            // Low is inclusive thus +1.
            low = low2 + 1
        } else {
            low = 1
        }
        return MsgRange(low: low, hi: hi)
    }

    func queryLatest() -> [StoredMessage]? {
        let messages2 = self.table.alias("m2")
        guard let topicDb = baseDb.topicDb else { return nil }
        let topics = topicDb.table

        let m2Id = Expression<Int64?>("id")
        let joinedTable = self.table.select(
            self.table[self.id],
            self.table[self.topicId],
            self.table[self.userId],
            self.table[self.status],
            self.table[self.sender],
            self.table[self.ts],
            self.table[self.seq],
            self.table[self.high],
            self.table[self.delId],
            self.table[self.head],
            self.table[self.content],
            topics[topicDb.topic])
        .join(.leftOuter, messages2,
              on: self.table[self.topicId] == messages2[self.topicId] && self.table[self.seq] < messages2[self.seq])
        .join(.leftOuter, topics, on: self.table[self.topicId] == topics[topicDb.id])
            .filter(self.table[self.delId] == nil && messages2[self.delId] == nil && messages2[m2Id] == nil)
        do {
            var messages = [StoredMessage]()
            for row in try db.prepare(joinedTable) {
                let sm = self.readOne(r: row)
                sm.topic = row[topicDb.topic]
                messages.append(sm)
            }
            return messages
        } catch {
            BaseDb.log.error("MessageDb - queryLatest operation failed: error = %@", error.localizedDescription)
            return nil
        }
    }
}
