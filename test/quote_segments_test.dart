import 'package:flutter_test/flutter_test.dart';
import 'package:manent/notes/quote_segments.dart';

void main() {
  test('plain text stays one segment', () {
    expect(splitQuoteSegments('a > b\nc'), [(quote: false, text: 'a > b\nc')]);
  });

  test('highlight note splits into quote and trailing text', () {
    const note = '> First\n>\n> Second\n\nComment\n#tag';
    expect(splitQuoteSegments(note), [
      (quote: true, text: 'First\n\nSecond'),
      (quote: false, text: '\nComment\n#tag'),
    ]);
  });

  test('marker without space and text around the quote', () {
    expect(splitQuoteSegments('intro\n>q1\n>  q2\nend'), [
      (quote: false, text: 'intro'),
      (quote: true, text: 'q1\n q2'),
      (quote: false, text: 'end'),
    ]);
  });

  test('indented marker is plain text', () {
    expect(splitQuoteSegments(' > not a quote'),
        [(quote: false, text: ' > not a quote')]);
  });
}
