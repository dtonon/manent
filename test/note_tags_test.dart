import 'package:flutter_test/flutter_test.dart';
import 'package:manent/search/note_tags.dart';

void main() {
  group('extractTags', () {
    test('picks up tags at start, mid-text and end', () {
      expect(extractTags('#work meeting notes'), {'work'});
      expect(extractTags('meeting notes #work'), {'work'});
      expect(extractTags('a #work b #ideas c'), {'work', 'ideas'});
    });

    test('lowercases for matching', () {
      expect(extractTags('#Work #WORK #work'), {'work'});
    });

    test('ignores a # that is not at a boundary', () {
      expect(extractTags('example.com/page#section'), isEmpty);
      expect(extractTags('written in C#'), isEmpty);
      expect(extractTags('a#b'), isEmpty);
    });

    test('ignores numeric and empty tags', () {
      expect(extractTags('issue #42 is open'), isEmpty);
      expect(extractTags('# heading'), isEmpty);
      expect(extractTags('just a # alone'), isEmpty);
    });

    test('allows unicode letters, digits after the first char, - and _', () {
      expect(extractTags('#café'), {'café'});
      expect(extractTags('#q1-2026'), {'q1-2026'});
      expect(extractTags('#my_tag'), {'my_tag'});
    });

    test('stops at punctuation following the tag', () {
      expect(extractTags('bought milk #groceries.'), {'groceries'});
      expect(extractTags('see #work, then #ideas;'), {'work', 'ideas'});
    });

    test('treats opening brackets and quotes as boundaries', () {
      expect(extractTags('(#work)'), {'work'});
      expect(extractTags('[#work]'), {'work'});
      expect(extractTags('"#work"'), {'work'});
      expect(extractTags("'#work'"), {'work'});
    });

    test('works across newlines', () {
      expect(extractTags('line one\n#work\nline two'), {'work'});
    });
  });

  group('tagMatches', () {
    test('reports offsets that exclude the leading whitespace', () {
      const text = 'ab #work cd';
      final matches = tagMatches(text).toList();
      expect(matches.length, 1);
      expect(text.substring(matches[0].start, matches[0].end), '#work');
      expect(matches[0].tag, 'work');
    });

    test('reports every tag in order', () {
      final matches = tagMatches('#a and #b').toList();
      expect(matches.map((m) => m.tag), ['a', 'b']);
    });
  });

  group('suggestTags', () {
    test('offers the defaults when nothing has been tagged', () {
      expect(suggestTags(const [], ''), containsAll(defaultTags));
    });

    test('narrows on the typed prefix', () {
      expect(suggestTags(const [], 'to'), ['todo']);
      expect(suggestTags(const [], 'zz'), isEmpty);
    });

    test('respects the limit', () {
      expect(suggestTags(const [], '').length, lessThanOrEqualTo(5));
    });
  });

  group('sortedTags', () {
    test('orders by count desc then alphabetically', () {
      final order = sortedTags({'b': 2, 'a': 2, 'c': 5});
      expect(order, ['c', 'a', 'b']);
    });
  });
}
