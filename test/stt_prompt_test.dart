import 'package:flutter_test/flutter_test.dart';
import 'package:manent/notes/note.dart';
import 'package:manent/stt/stt_prompt.dart';

DecryptedNote _note(int i, String text) => DecryptedNote(
      id: 'n$i',
      text: text,
      createdAt: DateTime(2026, 1, 1),
      syncStatus: SyncStatus.synced,
    );

void main() {
  test('always carries hashtag examples', () {
    final prompt = buildSttPrompt(const []);
    expect(prompt, contains('#todo'));
    expect(prompt, isNot(contains('Tags:')));
  });

  test('appends the most used tags first', () {
    final notes = [
      _note(1, '#rare'),
      _note(2, '#common'),
      _note(3, '#common'),
    ];
    expect(buildSttPrompt(notes), endsWith('Tags: #common #rare.'));
  });

  test('caps the user tags', () {
    final notes = [for (var i = 0; i < 20; i++) _note(i, '#tag$i')];
    final tags = buildSttPrompt(notes).split('Tags: ').last.split(' ');
    expect(tags.length, maxPromptTags);
  });
}
