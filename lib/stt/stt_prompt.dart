import '../notes/note.dart';
import '../search/note_tags.dart';

// Whisper reads this text before the audio and copies its conventions, so a
// few note-like lines in several languages teach it to write spoken
// "hashtag todo" as "#todo". The user's most used tags follow, which also
// steers their spelling. The prompt's languages do not affect detection.
const _styleLines = [
  'Note: buy bread #shopping, call Luca #todo.',
  'Nota: comprare il pane #spesa, chiamare Luca #todo.',
  'Nota: comprar pan #compras, llamar a Luca #todo.',
  'Notiz: Brot kaufen #einkauf, Luca anrufen #todo.',
  'Note : acheter du pain #courses, appeler Luca #todo.',
];
const maxPromptTags = 10;

String buildSttPrompt(List<DecryptedNote> notes) {
  final tags = sortedTags(tagCounts(notes)).take(maxPromptTags);
  return [
    ..._styleLines,
    if (tags.isNotEmpty) 'Tags: ${tags.map((t) => '#$t').join(' ')}.',
  ].join(' ');
}
