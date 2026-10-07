import 'package:flutter_test/flutter_test.dart';
import 'package:manent/notes/note_attachment.dart';

void main() {
  const base = NoteAttachment(
    filename: 'voice.ogg',
    mimeType: 'audio/ogg',
    size: 10,
    sha256: 'abc',
    key: 'def',
    caption: 'hello #tag',
    transcript: 'spoken words',
  );

  test('transcript round-trips through JSON', () {
    final parsed = NoteAttachment.fromJson(base.toJson());
    expect(parsed.caption, 'hello #tag');
    expect(parsed.transcript, 'spoken words');
  });

  test('transcript key is omitted when absent', () {
    final json = base.copyWith(clearTranscript: true).toJson();
    expect(json.containsKey('transcript'), isFalse);
    expect(NoteAttachment.fromJson(json).transcript, isNull);
  });

  test('voice note means audio with a transcript', () {
    expect(base.isVoiceNote, isTrue);
    expect(base.copyWith(clearTranscript: true).isVoiceNote, isFalse);
    const transcribedVideo = NoteAttachment(
      filename: 'clip.mp4',
      mimeType: 'video/mp4',
      size: 10,
      sha256: 'abc',
      key: 'def',
      transcript: 'words',
    );
    expect(transcribedVideo.isVoiceNote, isFalse);
  });

  test('copyWith keeps or clears each field independently', () {
    final edited = base.copyWith(caption: 'new caption');
    expect(edited.transcript, 'spoken words');
    final cleared = base.copyWith(clearCaption: true);
    expect(cleared.caption, isNull);
    expect(cleared.transcript, 'spoken words');
    final replaced = base.copyWith(transcript: 'again');
    expect(replaced.caption, 'hello #tag');
    expect(replaced.transcript, 'again');
  });
}
