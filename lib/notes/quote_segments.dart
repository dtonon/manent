typedef QuoteSegment = ({bool quote, String text});

final _quoteMarker = RegExp(r'^> ?');

// Splits text into runs of `>` quoted lines and plain lines. Quote markers are
// stripped; the line break between two runs is dropped since they render as
// separate blocks.
List<QuoteSegment> splitQuoteSegments(String text) {
  final segments = <QuoteSegment>[];
  final lines = <String>[];
  bool? inQuote;

  void flush() {
    if (inQuote != null) segments.add((quote: inQuote, text: lines.join('\n')));
    lines.clear();
  }

  for (final line in text.split('\n')) {
    final isQuote = line.startsWith('>');
    if (isQuote != inQuote) {
      flush();
      inQuote = isQuote;
    }
    lines.add(isQuote ? line.replaceFirst(_quoteMarker, '') : line);
  }
  flush();
  return segments;
}
