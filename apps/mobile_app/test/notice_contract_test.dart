import 'package:flutter_test/flutter_test.dart';
import 'package:messengerx_app/data/models.dart';
import 'package:messengerx_app/data/telegram_repository.dart';

void main() {
  test('notification preferences fail closed for missing preview fields', () {
    final saved = PushPreferences.fromMap(<String, dynamic>{
      'push_telegram': true,
      'push_preview': false,
    });
    expect(saved.telegram, isTrue);
    expect(saved.preview, isFalse);

    final incomplete = PushPreferences.fromMap(<String, dynamic>{});
    expect(incomplete.telegram, isFalse);
    expect(incomplete.preview, isFalse);
  });

  test('the Telegram-only sync direction matches the Postgres enum', () {
    final chat = MirroredChat.fromMap(<String, dynamic>{
      'tg_chat_id': '5001337420',
      'title': 'Dilnoza',
      'sync_direction': 'from_telegram',
    });
    expect(chat.directionLabel, 'Telegram → app');
  });
}
