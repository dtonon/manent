import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const ManentApp());
}

class ManentApp extends StatelessWidget {
  const ManentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Manent',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFe32a6d),
        ),
        useMaterial3: true,
      ),
      home: const NotesScreen(),
    );
  }
}

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final TextEditingController _textController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFFe32a6d),
        elevation: 0,
        title: const Text(
          'MANENT',
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.w500,
            letterSpacing: 2,
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildTextMessage(
                  'Proin luctus, libero eget volutpat sodales, magna orci sodales augue, quis volutpat tortor risus at https://njump.me.',
                  '19:02',
                ),
                const SizedBox(height: 12),
                _buildTextMessage(
                  'Proin luctus, libero eget volutpat sodales, magna nstart.me orci sodales augue, quis volutpat tortor risus dignissim tortor.',
                  '20:10',
                ),
                const SizedBox(height: 24),
                _buildDateSeparator('17 February'),
                const SizedBox(height: 12),
                _buildImageMessage(
                  'https://images.unsplash.com/photo-1574158622682-e40e69881006?w=800',
                  '12:31',
                ),
                const SizedBox(height: 12),
                _buildTextMessage(
                  'Proin luctus, libero eget volutpat sodales, magna orci sodales augue, quis volutpat tortor risus dignissim tortor. Etiam dapibus ultrices massa, euismod accumsan eros commodo vel. Integer faucibus auctor viverra. Ut et nisl a massa facilisis fringilla a a sem.',
                  '15:31',
                ),
                const SizedBox(height: 12),
                _buildTextMessage(
                  'Curabitur tristique, est in congue mattis, justo leo dapibus nisl, in lobortis lacus tellus vitae sem. Fusce ultrices iaculis vestibulum.\n\nAenean nec felis nec ex molestie efficitur et vitae ante.',
                  '15:34',
                ),
              ],
            ),
          ),
          _buildInputBar(context),
        ],
      ),
    );
  }

  Widget _buildTextMessage(String text, String time) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              children: _buildTextSpans(
                text,
                const TextStyle(
                  fontSize: 14,
                  height: 1.3,
                  color: Colors.black87,
                ),
              ),
            ),
          ),
          const SizedBox(height: 0),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              time,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[400],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static final _urlRegex = RegExp(
    r'https?://[^\s]+|[a-zA-Z0-9][a-zA-Z0-9\-]*\.[a-zA-Z]{2,}(?:/[^\s]*)?',
    caseSensitive: false,
  );

  List<InlineSpan> _buildTextSpans(String text, TextStyle baseStyle) {
    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in _urlRegex.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start), style: baseStyle));
      }

      // Strip trailing sentence punctuation
      String url = match.group(0)!.replaceAll(RegExp(r'[.,!?;:)]+$'), '');
      final fullUrl = url.startsWith('http') ? url : 'https://$url';

      spans.add(TextSpan(
        text: url,
        style: baseStyle.copyWith(
          color: const Color(0xFFe32a6d),
          decoration: TextDecoration.underline,
          decorationColor: const Color(0xFFe32a6d),
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () => launchUrl(Uri.parse(fullUrl), mode: LaunchMode.platformDefault),
      ));
      // Advance past stripped url only; trailing punctuation becomes plain text
      lastEnd = match.start + url.length;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd), style: baseStyle));
    }

    return spans;
  }

  Widget _buildImageMessage(String imageUrl, String time) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    height: 300,
                    color: Colors.grey[300],
                    child: const Center(
                      child: Icon(Icons.image, size: 64, color: Colors.grey),
                    ),
                  );
                },
              ),
              Positioned(
                bottom: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    time,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.black87,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDateSeparator(String date) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFe32a6d),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        date,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildInputBar(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.5;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              offset: const Offset(0, -1),
              blurRadius: 4,
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(
                  hintText: 'Memo...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(
                    color: Colors.grey,
                    fontSize: 14,
                  ),
                ),
                style: const TextStyle(fontSize: 14),
              ),
            ),
            const SizedBox(width: 12),
            Icon(Icons.attach_file, color: Colors.grey[700]),
            const SizedBox(width: 16),
            Icon(Icons.mic, color: Colors.grey[700]),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }
}
