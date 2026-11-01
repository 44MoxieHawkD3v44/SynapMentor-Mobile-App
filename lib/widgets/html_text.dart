import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../core/html_entities.dart';
import '../core/theme.dart';
import 'glass.dart';
import 'true_colors.dart';

/// Renders the HTML a blog can use: headings, paragraphs, line breaks,
/// bulleted and numbered lists, bold, italic, underline, links (tappable),
/// code, quotes and pictures. Scripts, styles, the page head, comments and
/// declarations such as <!DOCTYPE html> are dropped.
class HtmlText extends StatefulWidget {
  const HtmlText(this.html, {super.key});

  final String html;

  /// Where a picture in a blog loads from: web links as they are, the API's
  /// own links (e.g. `/api/v1/public/content/blog-images/<id>`) on the API
  /// server, and anything else as a file on this device (a picture the solver
  /// added before it was uploaded).
  static String resolveImage(String src) {
    final s = src.trim();
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    if (s.startsWith('//')) return 'https:$s';
    if (s.startsWith('/api/')) return '${ApiConfig.baseUrl}$s';
    return s;
  }

  @override
  State<HtmlText> createState() => _HtmlTextState();
}

class _HtmlTextState extends State<HtmlText> {
  static final _unsafe = RegExp(r'<(script|style|iframe)[^>]*>[\s\S]*?</\1>', caseSensitive: false);

  /// Parts of a full HTML page that aren't the post: the document head (its
  /// page title), comments, and declarations such as <!DOCTYPE html>.
  static final _notContent = RegExp(
    r'<head[\s>][\s\S]*?</head>|<(title|noscript|template)[^>]*>[\s\S]*?</\1>|<!--[\s\S]*?(-->|$)|<![^>]*>|<\?[\s\S]*?\?>',
    caseSensitive: false,
  );
  static final _token = RegExp(r'<(/?)([a-zA-Z0-9]+)[^>]*>|([^<]+)');
  static final _src = RegExp(r'''src\s*=\s*["']([^"']+)["']''', caseSensitive: false);
  static final _href = RegExp(r'''href\s*=\s*["']([^"']+)["']''', caseSensitive: false);
  static const _blocks = {'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'pre', 'blockquote'};

  /// Tap handlers for the links on screen, released when the text changes.
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  TapGestureRecognizer _linkTo(String href) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () {
        final uri = Uri.tryParse(href.trim());
        if (uri == null || !const {'http', 'https', 'mailto', 'tel'}.contains(uri.scheme)) return;
        launchUrl(uri, mode: LaunchMode.externalApplication);
      };
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();
    final source = widget.html.replaceAll(_notContent, '').replaceAll(_unsafe, '');
    final blocks = <(String, List<InlineSpan>)>[];
    var spans = <InlineSpan>[];
    var block = 'p';

    /// Text outside any block tag, as Visual mode writes it: a single line
    /// break there is kept. Inside tags, line breaks are just layout.
    var loose = true;
    var bold = 0, italic = 0, underline = 0, code = 0;
    final links = <String?>[];

    /// Open lists, innermost last: the count so far for a numbered list,
    /// null for a bulleted one.
    final lists = <int?>[];

    void flush() {
      // A block doesn't end on an empty line.
      while (spans.isNotEmpty) {
        final last = spans.last;
        if (last is! TextSpan || last.text == null || !last.text!.endsWith('\n')) break;
        final trimmed = last.text!.replaceFirst(RegExp(r'\n+$'), '');
        spans.removeLast();
        if (trimmed.isNotEmpty) {
          spans.add(TextSpan(text: trimmed, style: last.style, recognizer: last.recognizer));
          break;
        }
      }
      if (spans.isNotEmpty) blocks.add((block, spans));
      spans = [];
      block = 'p';
      loose = true;
    }

    for (final m in _token.allMatches(source)) {
      final text = m.group(3);
      if (text != null) {
        // Plain text keeps its own paragraph breaks.
        final parts = decodeHtmlEntities(text).split(RegExp(r'\n\s*\n'));
        for (final (i, part) in parts.indexed) {
          if (i > 0) flush();
          var value = block == 'pre'
              ? part
              : loose
              ? part.replaceAll(RegExp(r'[ \t]*\n[ \t]*'), '\n').replaceAll(RegExp(r'[ \t\r\f]+'), ' ')
              : part.replaceAll(RegExp(r'\s+'), ' ');
          // A block doesn't start with an empty line.
          if (spans.isEmpty && block != 'pre') value = value.replaceFirst(RegExp(r'^\n+'), '');
          if (value.trim().isEmpty && block != 'pre') continue;
          final href = links.lastWhere((l) => l != null, orElse: () => null);
          spans.add(
            TextSpan(
              text: value,
              recognizer: href == null ? null : _linkTo(href),
              style: TextStyle(
                fontWeight: bold > 0 ? FontWeight.w700 : null,
                fontStyle: italic > 0 ? FontStyle.italic : null,
                fontFamily: code > 0 || block == 'pre' ? 'monospace' : null,
                backgroundColor: code > 0 ? AppColors.white(0.12) : null,
                decoration: links.isNotEmpty || underline > 0 ? TextDecoration.underline : null,
                decorationColor: Colors.white,
              ),
            ),
          );
        }
        continue;
      }
      final closing = m.group(1) == '/';
      final tag = m.group(2)!.toLowerCase();
      if (tag == 'img') {
        // Pictures sit on their own line.
        final src = _src.firstMatch(m.group(0)!)?.group(1);
        if (src != null) {
          flush();
          blocks.add(('img:$src', const []));
        }
        continue;
      }
      final delta = closing ? -1 : 1;
      if (tag == 'ul' || tag == 'ol') {
        flush();
        if (closing) {
          if (lists.isNotEmpty) lists.removeLast();
        } else {
          lists.add(tag == 'ol' ? 0 : null);
        }
      } else if (_blocks.contains(tag)) {
        flush();
        if (!closing) {
          loose = false;
          if (tag == 'li' && lists.isNotEmpty && lists.last != null) {
            lists[lists.length - 1] = lists.last! + 1;
            block = 'li#${lists.last}';
          } else {
            block = tag;
          }
        }
      } else if (tag == 'br') {
        spans.add(const TextSpan(text: '\n'));
      } else if (tag == 'b' || tag == 'strong') {
        bold = (bold + delta).clamp(0, 9);
      } else if (tag == 'i' || tag == 'em') {
        italic = (italic + delta).clamp(0, 9);
      } else if (tag == 'u' || tag == 'ins') {
        underline = (underline + delta).clamp(0, 9);
      } else if (tag == 'code') {
        code = (code + delta).clamp(0, 9);
      } else if (tag == 'a') {
        if (closing) {
          if (links.isNotEmpty) links.removeLast();
        } else {
          links.add(_href.firstMatch(m.group(0)!)?.group(1));
        }
      }
    }
    flush();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, (tag, content)) in blocks.indexed)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : (tag.startsWith('h') ? 14 : (tag.startsWith('li') ? 4 : 10))),
            child: _block(tag, content),
          ),
      ],
    );
  }

  /// Web and API links load from the network; pictures added from the device
  /// (before upload) load from their file.
  Widget _image(String src) {
    final broken = Icon(Icons.broken_image_outlined, size: 40, color: AppColors.white(0.6));
    final url = HtmlText.resolveImage(src);
    final Widget image = url.startsWith('http')
        ? Image.network(
            url,
            fit: BoxFit.contain,
            headers: ApiClient.instance.imageHeaders(url),
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : const SizedBox(
                    height: 160,
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)),
                  ),
            errorBuilder: (_, _, _) => broken,
          )
        : kIsWeb || url.startsWith('data:')
        ? broken
        : Image.file(File(url), fit: BoxFit.contain, errorBuilder: (_, _, _) => broken);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: TrueColors(child: image),
    );
  }

  Widget _block(String tag, List<InlineSpan> content) {
    if (tag.startsWith('img:')) return _image(tag.substring(4));
    final style = switch (tag) {
      'h1' => const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white, height: 1.3),
      'h2' => const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Colors.white, height: 1.3),
      'h3' ||
      'h4' ||
      'h5' ||
      'h6' => const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white, height: 1.3),
      _ => const TextStyle(fontSize: 14, color: Colors.white, height: 1.55),
    };
    final text = Text.rich(TextSpan(style: style, children: content));
    if (tag.startsWith('li')) {
      // Numbered lists show their number; others a bullet.
      final number = tag.startsWith('li#') ? '${tag.substring(3)}.  ' : '•  ';
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(number, style: style),
          Expanded(child: text),
        ],
      );
    }
    return switch (tag) {
      'pre' => GlassWell(radius: 12, padding: const EdgeInsets.all(12), child: text),
      'blockquote' => Container(
        padding: const EdgeInsets.only(left: 12),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: AppColors.white(0.4), width: 2)),
        ),
        child: text,
      ),
      _ => text,
    };
  }
}
