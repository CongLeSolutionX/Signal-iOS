//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

public class MessageBackupChatItemArchiverImpl: MessageBackupChatItemArchiver {
    private typealias ArchiveFrameError = MessageBackup.ArchiveFrameError<MessageBackup.InteractionUniqueId>

    private let callRecordStore: CallRecordStore
    private let contactManager: MessageBackup.Shims.ContactManager
    private let dateProvider: DateProvider
    private let groupCallRecordManager: GroupCallRecordManager
    private let groupUpdateHelper: GroupUpdateInfoMessageInserterBackupHelper
    private let groupUpdateItemBuilder: GroupUpdateItemBuilder
    private let individualCallRecordManager: IndividualCallRecordManager
    private let interactionStore: InteractionStore
    private let archivedPaymentStore: ArchivedPaymentStore
    private let reactionStore: ReactionStore
    private let sentMessageTranscriptReceiver: SentMessageTranscriptReceiver
    private let threadStore: ThreadStore

    public init(
        callRecordStore: CallRecordStore,
        contactManager: MessageBackup.Shims.ContactManager,
        dateProvider: @escaping DateProvider,
        groupCallRecordManager: GroupCallRecordManager,
        groupUpdateHelper: GroupUpdateInfoMessageInserterBackupHelper,
        groupUpdateItemBuilder: GroupUpdateItemBuilder,
        individualCallRecordManager: IndividualCallRecordManager,
        interactionStore: InteractionStore,
        archivedPaymentStore: ArchivedPaymentStore,
        reactionStore: ReactionStore,
        sentMessageTranscriptReceiver: SentMessageTranscriptReceiver,
        threadStore: ThreadStore
    ) {
        self.callRecordStore = callRecordStore
        self.contactManager = contactManager
        self.dateProvider = dateProvider
        self.groupCallRecordManager = groupCallRecordManager
        self.groupUpdateHelper = groupUpdateHelper
        self.groupUpdateItemBuilder = groupUpdateItemBuilder
        self.individualCallRecordManager = individualCallRecordManager
        self.interactionStore = interactionStore
        self.archivedPaymentStore = archivedPaymentStore
        self.reactionStore = reactionStore
        self.sentMessageTranscriptReceiver = sentMessageTranscriptReceiver
        self.threadStore = threadStore
    }

    private lazy var reactionArchiver = MessageBackupReactionArchiver(
        reactionStore: reactionStore
    )
    private lazy var contentsArchiver = MessageBackupTSMessageContentsArchiver(
        interactionStore: interactionStore,
        archivedPaymentStore: archivedPaymentStore,
        reactionArchiver: reactionArchiver
    )
    private lazy var incomingMessageArchiver =
        MessageBackupTSIncomingMessageArchiver(
            contentsArchiver: contentsArchiver,
            interactionStore: interactionStore
        )
    private lazy var outgoingMessageArchiver =
        MessageBackupTSOutgoingMessageArchiver(
            contentsArchiver: contentsArchiver,
            interactionStore: interactionStore,
            sentMessageTranscriptReceiver: sentMessageTranscriptReceiver
        )
    private lazy var chatUpdateMessageArchiver =
        MessageBackupChatUpdateMessageArchiver(
            callRecordStore: callRecordStore,
            contactManager: contactManager,
            groupCallRecordManager: groupCallRecordManager,
            groupUpdateHelper: groupUpdateHelper,
            groupUpdateItemBuilder: groupUpdateItemBuilder,
            individualCallRecordManager: individualCallRecordManager,
            interactionStore: interactionStore
        )

    public func archiveInteractions(
        stream: MessageBackupProtoOutputStream,
        context: MessageBackup.ChatArchivingContext,
        tx: DBReadTransaction
    ) -> ArchiveMultiFrameResult {
        var completeFailureError: MessageBackup.FatalArchivingError?
        var partialFailures = [ArchiveFrameError]()

        func archiveInteraction(
            _ interaction: TSInteraction
        ) -> Bool {
            let result = self.archiveInteraction(
                interaction,
                stream: stream,
                context: context,
                tx: tx
            )
            switch result {
            case .success:
                break
            case .partialSuccess(let errors):
                partialFailures.append(contentsOf: errors)
            case .completeFailure(let error):
                completeFailureError = error
                return false
            }

            return true
        }

        do {
            try interactionStore.enumerateAllInteractions(
                tx: tx,
                block: archiveInteraction(_:)
            )
        } catch let error {
            // Errors thrown here are from the iterator's SQL query,
            // not the individual interaction handler.
            return .completeFailure(.fatalArchiveError(.interactionIteratorError(error)))
        }

        if let completeFailureError {
            return .completeFailure(completeFailureError)
        } else if partialFailures.isEmpty {
            return .success
        } else {
            return .partialSuccess(partialFailures)
        }
    }

    private func archiveInteraction(
        _ interaction: TSInteraction,
        stream: MessageBackupProtoOutputStream,
        context: MessageBackup.ChatArchivingContext,
        tx: DBReadTransaction
    ) -> ArchiveMultiFrameResult {
        var partialErrors = [ArchiveFrameError]()

        guard
            let chatId = context[interaction.uniqueThreadIdentifier],
            let thread = threadStore.fetchThreadForInteraction(interaction, tx: tx)
        else {
            partialErrors.append(.archiveFrameError(
                .referencedThreadIdMissing(interaction.uniqueThreadIdentifier),
                interaction.uniqueInteractionId
            ))
            return .partialSuccess(partialErrors)
        }

        if
            let groupThread = thread as? TSGroupThread,
            groupThread.isGroupV1Thread
        {
            /// We are knowingly dropping GV1 data from backups, so we'll skip
            /// archiving any interactions for GV1 threads without errors.
            return .success
        }

        let archiver: MessageBackupInteractionArchiver
        switch interaction {
        case is TSIncomingMessage:
            archiver = incomingMessageArchiver
        case is TSOutgoingMessage:
            archiver = outgoingMessageArchiver
        case is TSInfoMessage: fallthrough
        case is TSErrorMessage: fallthrough
        case is TSCall: fallthrough
        case is OWSGroupCallMessage:
            archiver = chatUpdateMessageArchiver
        default:
            // TODO: [Backups] When we have a complete set of archivers, this should be a hard failure. For now, there's interactions we don't handle, so we'll ignore it.
            return .success
        }

        let result = archiver.archiveInteraction(
            interaction,
            thread: thread,
            context: context,
            tx: tx
        )

        let details: MessageBackup.InteractionArchiveDetails
        switch result {
        case .success(let deets):
            details = deets

        case
                .isPastRevision,
                .skippableChatUpdate,
                .notYetImplemented:
            // Skip! Say it succeeded so we ignore it.
            return .success

        case .messageFailure(let errors):
            partialErrors.append(contentsOf: errors)
            return .partialSuccess(partialErrors)
        case .partialFailure(let deets, let errors):
            partialErrors.append(contentsOf: errors)
            details = deets
        case .completeFailure(let error):
            return .completeFailure(error)
        }

        let minExpireTime = dateProvider().ows_millisecondsSince1970
            + MessageBackup.Constants.minExpireTimerMs
        if
            let expireStartDate = details.expireStartDate,
            let expiresInMs = details.expiresInMs,
            expiresInMs > 0, // Only check expiration if `expiresInMs` is set to something interesting.
            expireStartDate + expiresInMs < minExpireTime
        {
            // Skip this message, but count it as a success.
            return .success
        }

        var chatItem = BackupProto_ChatItem()
        chatItem.chatID = chatId.value
        chatItem.authorID = details.author.value
        chatItem.dateSent = interaction.timestamp
        chatItem.expireStartDate = details.expireStartDate ?? 0
        chatItem.expiresInMs = details.expiresInMs ?? 0
        chatItem.sms = details.isSms
        chatItem.item = details.chatItemType
        chatItem.directionalDetails = details.directionalDetails
        chatItem.revisions = details.revisions

        let error = Self.writeFrameToStream(
            stream,
            objectId: interaction.uniqueInteractionId
        ) {
            var frame = BackupProto_Frame()
            frame.item = .chatItem(chatItem)
            return frame
        }

        if let error {
            partialErrors.append(error)
            return .partialSuccess(partialErrors)
        } else if partialErrors.isEmpty {
            return .success
        } else {
            return .partialSuccess(partialErrors)
        }
    }

    public func restore(
        _ chatItem: BackupProto_ChatItem,
        context: MessageBackup.ChatRestoringContext,
        tx: DBWriteTransaction
    ) -> RestoreFrameResult {
        func restoreFrameError(
            _ error: MessageBackup.RestoreFrameError<MessageBackup.ChatItemId>.ErrorType,
            line: UInt = #line
        ) -> RestoreFrameResult {
            return .failure([.restoreFrameError(error, chatItem.id, line: line)])
        }

        switch context.recipientContext[chatItem.authorRecipientId] {
        case .releaseNotesChannel:
            // The release notes channel doesn't exist yet, so for the time
            // being we'll drop all chat items destined for it.
            //
            // TODO: [Backups] Implement restoring chat items into the release notes channel chat.
            return .success
        default:
            break
        }

        guard let threadUniqueId = context[chatItem.typedChatId] else {
            return restoreFrameError(.invalidProtoData(.chatIdNotFound(chatItem.typedChatId)))
        }

        guard
            let threadRaw = threadStore.fetchThread(uniqueId: threadUniqueId.value, tx: tx),
            let threadRowId = threadRaw.sqliteRowId
        else {
            return restoreFrameError(.referencedChatThreadNotFound(threadUniqueId))
        }

        let thread: MessageBackup.ChatThread
        if let contactThread = threadRaw as? TSContactThread {
            thread = MessageBackup.ChatThread(
                threadType: .contact(contactThread),
                threadRowId: threadRowId
            )
        } else if let groupThread = threadRaw as? TSGroupThread, groupThread.isGroupV2Thread {
            thread = MessageBackup.ChatThread(
                threadType: .groupV2(groupThread),
                threadRowId: threadRowId
            )
        } else {
            // It should be enforced by ChatRestoringContext that any
            // thread ID in it maps to a valid TSContact- or TSGroup- thread.
            return .failure([.restoreFrameError(
                .developerError(OWSAssertionError("Invalid TSThread type for chatId")),
                chatItem.id
            )])
        }

        let archiver: MessageBackupInteractionArchiver
        switch chatItem.directionalDetails {
        case nil:
            return restoreFrameError(.invalidProtoData(.chatItemMissingDirectionalDetails))
        case .incoming:
            archiver = incomingMessageArchiver
        case .outgoing:
            archiver = outgoingMessageArchiver
        case .directionless:
            switch chatItem.item {
            case nil:
                return restoreFrameError(.invalidProtoData(.chatItemMissingItem))
            case .standardMessage, .contactMessage, .giftBadge, .paymentNotification, .remoteDeletedMessage, .stickerMessage:
                return restoreFrameError(.invalidProtoData(.directionlessChatItemNotUpdateMessage))
            case .updateMessage:
                archiver = chatUpdateMessageArchiver
            }
        }

        let result = archiver.restoreChatItem(
            chatItem,
            chatThread: thread,
            context: context,
            tx: tx
        )

        switch result {
        case .success:
            return .success
        case .partialRestore(_, let errors):
            return .partialRestore(errors)
        case .messageFailure(let errors):
            return .failure(errors)
        }
    }
}
