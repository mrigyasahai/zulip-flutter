import 'package:checks/checks.dart';
import 'package:test/scaffolding.dart';
import 'package:zulip/api/model/events.dart';
import 'package:zulip/api/model/model.dart';
import 'package:zulip/api/route/messages.dart';
import 'package:zulip/model/message_list.dart';
import 'package:zulip/model/narrow.dart';

import '../api/fake_api.dart';
import '../api/model/model_checks.dart';
import '../example_data.dart' as eg;

const int userId = 1;

Future<MessageListView> messageListViewWithMessages(List<Message> messages, Narrow narrow) async {
  final store = eg.store();
  final messageList = MessageListView.init(store: store, narrow: narrow);

  final connection = store.connection as FakeApiConnection;
  connection.prepare(json: GetMessagesResult(
    anchor: messages.first.id,
    foundNewest: true,
    foundOldest: true,
    foundAnchor: true,
    historyLimited: false,
    messages: messages,
  ).toJson());
  await messageList.fetch();

  return messageList;
}

void main() async {
  final stream = eg.stream();
  final narrow = StreamNarrow(stream.streamId);

  test('findMessageWithId', () async {
    final m1 = eg.streamMessage(id: 2, stream: stream);
    final m2 = eg.streamMessage(id: 4, stream: stream);
    final m3 = eg.streamMessage(id: 6, stream: stream);
    final messageList = await messageListViewWithMessages([m1, m2, m3], narrow);

    // Exercise the binary search before, at, and after each element of the list.
    check(messageList.findMessageWithId(1)).equals(-1);
    check(messageList.findMessageWithId(2)).equals(0);
    check(messageList.findMessageWithId(3)).equals(-1);
    check(messageList.findMessageWithId(4)).equals(1);
    check(messageList.findMessageWithId(5)).equals(-1);
    check(messageList.findMessageWithId(6)).equals(2);
    check(messageList.findMessageWithId(7)).equals(-1);
  });

  group('maybeUpdateMessage', () {
    test('update a message', () async {
      final originalMessage = eg.streamMessage(id: 243, stream: stream,
        content: "<p>Hello, world</p>");
      final updateEvent = UpdateMessageEvent(
        id: 1,
        messageId: originalMessage.id,
        messageIds: [originalMessage.id],
        flags: ["starred"],
        renderedContent: "<p>Hello, edited</p>",
        editTimestamp: 99999,
        isMeMessage: true,
        userId: userId,
        renderingOnly: false,
      );

      final messageList = await messageListViewWithMessages([originalMessage], narrow);
      bool listenersNotified = false;
      messageList.addListener(() { listenersNotified = true; });

      final message = messageList.messages.single;
      check(message)
        ..content.not(it()..equals(updateEvent.renderedContent!))
        ..lastEditTimestamp.isNull()
        ..flags.not(it()..deepEquals(updateEvent.flags))
        ..isMeMessage.not(it()..equals(updateEvent.isMeMessage!));

      messageList.maybeUpdateMessage(updateEvent);
      check(listenersNotified).isTrue();
      check(messageList.messages.single)
        ..identicalTo(message)
        ..content.equals(updateEvent.renderedContent!)
        ..lastEditTimestamp.equals(updateEvent.editTimestamp)
        ..flags.equals(updateEvent.flags)
        ..isMeMessage.equals(updateEvent.isMeMessage!);
    });

    test('ignore when message not present', () async {
      final originalMessage = eg.streamMessage(id: 243, stream: stream,
        content: "<p>Hello, world</p>");
      final updateEvent = UpdateMessageEvent(
        id: 1,
        messageId: originalMessage.id + 1,
        messageIds: [originalMessage.id + 1],
        flags: originalMessage.flags,
        renderedContent: "<p>Hello, edited</p>",
        editTimestamp: 99999,
        userId: userId,
        renderingOnly: false,
      );

      final messageList = await messageListViewWithMessages([originalMessage], narrow);
      bool listenersNotified = false;
      messageList.addListener(() { listenersNotified = true; });

      messageList.maybeUpdateMessage(updateEvent);
      check(listenersNotified).isFalse();
      check(messageList.messages.single)
        ..content.equals(originalMessage.content)
        ..content.not(it()..equals(updateEvent.renderedContent!));
    });

    // TODO(server-5): Cut legacy case for rendering-only message update
    Future<void> checkRenderingOnly({required bool legacy}) async {
      final originalMessage = eg.streamMessage(id: 972, stream: stream,
        lastEditTimestamp: 78492,
        content: "<p>Hello, world</p>");
      final updateEvent = UpdateMessageEvent(
        id: 1,
        messageId: originalMessage.id,
        messageIds: [originalMessage.id],
        flags: originalMessage.flags,
        renderedContent: "<p>Hello, world</p> <div>Some link preview</div>",
        editTimestamp: 99999,
        renderingOnly: legacy ? null : true,
        userId: null,
      );

      final messageList = await messageListViewWithMessages([originalMessage], narrow);
      bool listenersNotified = false;
      messageList.addListener(() { listenersNotified = true; });

      final message = messageList.messages.single;
      messageList.maybeUpdateMessage(updateEvent);
      check(listenersNotified).isTrue();
      check(messageList.messages.single)
        ..identicalTo(message)
        // Content is updated...
        ..content.equals(updateEvent.renderedContent!)
        // ... edit timestamp is not.
        ..lastEditTimestamp.equals(originalMessage.lastEditTimestamp)
        ..lastEditTimestamp.not(it()..equals(updateEvent.editTimestamp));
    }

    test('rendering-only update does not change timestamp', () async {
      await checkRenderingOnly(legacy: false);
    });

    test('rendering-only update does not change timestamp (for old server versions)', () async {
      await checkRenderingOnly(legacy: true);
    });

    group('ReactionEvent handling', () {
      ReactionEvent mkEvent(Reaction reaction, ReactionOp op, int messageId) {
        return ReactionEvent(
          id: 1,
          op: op,
          emojiName: reaction.emojiName,
          emojiCode: reaction.emojiCode,
          reactionType: reaction.reactionType,
          userId: reaction.userId,
          messageId: messageId,
        );
      }

      test('add reaction', () async {
        final originalMessage = eg.streamMessage(stream: stream, reactions: []);
        final messageList = await messageListViewWithMessages([originalMessage], narrow);

        final message = messageList.messages.single;

        bool listenersNotified = false;
        messageList.addListener(() { listenersNotified = true; });

        messageList.maybeUpdateMessageReactions(
          mkEvent(eg.unicodeEmojiReaction, ReactionOp.add, originalMessage.id));

        check(listenersNotified).isTrue();
        check(messageList.messages.single)
          ..identicalTo(message)
          ..reactions.jsonEquals([eg.unicodeEmojiReaction]);
      });

      test('add reaction; message is not in list', () async {
        final someMessage = eg.streamMessage(id: 1, reactions: []);
        final messageList = await messageListViewWithMessages([someMessage], narrow);

        bool listenersNotified = false;
        messageList.addListener(() { listenersNotified = true; });

        messageList.maybeUpdateMessageReactions(
          mkEvent(eg.unicodeEmojiReaction, ReactionOp.add, 1000));

        check(listenersNotified).isFalse();
        check(messageList.messages.single).reactions.jsonEquals([]);
      });

      test('remove reaction', () async {
        final eventReaction = Reaction(reactionType: ReactionType.unicodeEmoji,
          emojiName: 'wave',                  emojiCode: '1f44b', userId: 1);

        // Same emoji, different user. Not to be removed.
        final reaction2 = Reaction.fromJson(eventReaction.toJson()
          ..['user_id'] = 2);

        // Same user, different emoji. Not to be removed.
        final reaction3 = Reaction.fromJson(eventReaction.toJson()
          ..['emoji_code'] = '1f6e0'
          ..['emoji_name'] = 'working_on_it');

        // Same user, same emojiCode, different emojiName. To be removed: servers
        // key on user, message, reaction type, and emoji code, but not emoji name.
        // So we mimic that behavior; see discussion:
        //   https://github.com/zulip/zulip-flutter/pull/256#discussion_r1284865099
        final reaction4 = Reaction.fromJson(eventReaction.toJson()
          ..['emoji_name'] = 'hello');

        final originalMessage = eg.streamMessage(stream: stream,
          reactions: [reaction2, reaction3, reaction4]);
        final messageList = await messageListViewWithMessages([originalMessage], narrow);

        final message = messageList.messages.single;

        bool listenersNotified = false;
        messageList.addListener(() { listenersNotified = true; });

        messageList.maybeUpdateMessageReactions(
          mkEvent(eventReaction, ReactionOp.remove, originalMessage.id));

        check(listenersNotified).isTrue();
        check(messageList.messages.single)
          ..identicalTo(message)
          ..reactions.jsonEquals([reaction2, reaction3]);
      });

      test('remove reaction; message is not in list', () async {
        final someMessage = eg.streamMessage(id: 1, reactions: [eg.unicodeEmojiReaction]);
        final messageList = await messageListViewWithMessages([someMessage], narrow);

        bool listenersNotified = false;
        messageList.addListener(() { listenersNotified = true; });

        messageList.maybeUpdateMessageReactions(
          mkEvent(eg.unicodeEmojiReaction, ReactionOp.remove, 1000));

        check(listenersNotified).isFalse();
        check(messageList.messages.single).reactions.jsonEquals([eg.unicodeEmojiReaction]);
      });
    });
  });
}
