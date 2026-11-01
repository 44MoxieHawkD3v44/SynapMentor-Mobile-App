import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import 'glass.dart';
import 'glass_controls.dart';
import 'true_colors.dart';

// Pieces shared by the community and session chats: swipe-to-reply, the
// replied-to message, and attachments that open inside the app.

/// Swipe a message to the right to reply to it.
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({super.key, required this.child, required this.onReply});

  final Widget child;
  final VoidCallback onReply;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> {
  static const _max = 72.0;
  static const _trigger = 52.0;
  double _dx = 0;
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (d) => setState(() {
        _dx = (_dx + d.delta.dx).clamp(0.0, _max);
        final armed = _dx >= _trigger;
        if (armed && !_armed) HapticFeedback.selectionClick();
        _armed = armed;
      }),
      onHorizontalDragEnd: (_) {
        if (_armed) widget.onReply();
        setState(() {
          _dx = 0;
          _armed = false;
        });
      },
      onHorizontalDragCancel: () => setState(() {
        _dx = 0;
        _armed = false;
      }),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned(
            left: 4,
            child: Icon(
              Icons.reply_rounded,
              size: 22,
              color: AppColors.white(_dx == 0 ? 0 : (_dx / _trigger).clamp(0.2, 1)),
            ),
          ),
          AnimatedContainer(
            duration: Duration(milliseconds: _dx == 0 ? 200 : 0),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(_dx, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

/// The message being replied to, above the composer, with a way to cancel.
class ReplyComposerBar extends StatelessWidget {
  const ReplyComposerBar({super.key, required this.author, required this.text, required this.onCancel});

  final String author;
  final String text;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassWell(
        radius: 16,
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Container(width: 3, height: 34, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Replying to $author',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                  Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Cancel reply',
              visualDensity: VisualDensity.compact,
              onPressed: onCancel,
              icon: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

/// The replied-to message, quoted at the top of a reply.
class QuotedReply extends StatelessWidget {
  const QuotedReply({super.key, required this.text, this.author});

  final String? author;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: AppColors.white(0.08),
        borderRadius: BorderRadius.circular(10),
        border: const Border(left: BorderSide(color: Colors.white, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (author != null)
            Text(
              author!,
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white),
            ),
          Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(fontSize: 12)),
        ],
      ),
    );
  }
}

/// Whether a shared file is a picture, by its type or name.
bool isImageFile(String? name, [String? contentType]) {
  if (contentType != null && contentType.startsWith('image/')) return true;
  final ext = (name ?? '').split('.').last.toLowerCase();
  return const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'}.contains(ext);
}

/// A shared file in a message: a picture shows as a thumbnail, anything else
/// as its name. Tapping opens it inside the app.
class AttachmentPreview extends StatelessWidget {
  const AttachmentPreview({super.key, required this.name, this.url, this.localPath, this.contentType});

  final String name;

  /// Where it can be downloaded, once the server has it.
  final String? url;

  /// The copy on this device, for files the user just sent.
  final String? localPath;
  final String? contentType;

  bool get _openable => (url != null && url!.isNotEmpty) || localPath != null;

  @override
  Widget build(BuildContext context) {
    final image = isImageFile(name, contentType);
    final open = _openable
        ? () => openAttachment(context, name: name, url: url, localPath: localPath, contentType: contentType)
        : null;
    if (image && _openable) {
      final picture = localPath != null
          ? Image.file(File(localPath!), fit: BoxFit.cover, errorBuilder: (_, _, _) => _fileRow(null))
          : Image.network(
              url!,
              fit: BoxFit.cover,
              loadingBuilder: (_, child, progress) => progress == null
                  ? child
                  : const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
              errorBuilder: (_, _, _) => _fileRow(null),
            );
      return Semantics(
        button: true,
        label: 'Open picture $name',
        child: GestureDetector(
          onTap: open,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(width: 220, height: 160, child: TrueColors(child: picture)),
          ),
        ),
      );
    }
    return _fileRow(open);
  }

  Widget _fileRow(VoidCallback? onTap) {
    return Semantics(
      button: onTap != null,
      label: 'Open file $name',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_iconFor(name), size: 18, color: Colors.white),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  name,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    decoration: onTap == null ? null : TextDecoration.underline,
                    decorationColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(String name) => switch (name.split('.').last.toLowerCase()) {
    'pdf' => Icons.picture_as_pdf_outlined,
    'doc' || 'docx' || 'txt' || 'md' => Icons.description_outlined,
    'xls' || 'xlsx' || 'csv' => Icons.table_chart_outlined,
    'ppt' || 'pptx' => Icons.slideshow_outlined,
    'mp4' || 'mov' || 'webm' => Icons.movie_outlined,
    'zip' || 'rar' => Icons.folder_zip_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

/// Opens a shared file inside the app: pictures zoomable, documents in a
/// viewer.
Future<void> openAttachment(
  BuildContext context, {
  required String name,
  String? url,
  String? localPath,
  String? contentType,
}) async {
  final remote = url != null && url.isNotEmpty ? Uri.tryParse(url) : null;
  if (!isImageFile(name, contentType) && remote == null) {
    // Only on this device so far: the phone's own viewer opens it.
    if (localPath != null) await launchUrl(Uri.file(localPath));
    return;
  }
  await Navigator.of(context)
      .push(glassRoute(_AttachmentScreen(name: name, url: remote, localPath: localPath, contentType: contentType)));
}

class _AttachmentScreen extends StatefulWidget {
  const _AttachmentScreen({required this.name, this.url, this.localPath, this.contentType});

  final String name;
  final Uri? url;
  final String? localPath;
  final String? contentType;

  @override
  State<_AttachmentScreen> createState() => _AttachmentScreenState();
}

class _AttachmentScreenState extends State<_AttachmentScreen> {
  WebViewController? _web;
  bool _loading = true;

  bool get _image => isImageFile(widget.name, widget.contentType);

  @override
  void initState() {
    super.initState();
    final url = widget.url;
    if (_image || url == null) return;
    final ext = widget.name.split('.').last.toLowerCase();
    // Documents go through a viewer that renders them in the page; other
    // files (text, video, web pages) load as they are.
    final document = const {'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx'}.contains(ext);
    final page = document ? Uri.https('docs.google.com', '/viewer', {'url': url.toString(), 'embedded': 'true'}) : url;
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
        ),
      )
      ..loadRequest(page);
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    final Widget body;
    if (_image) {
      body = InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: TrueColors(
            child: widget.localPath != null
                ? Image.file(File(widget.localPath!))
                : Image.network(
                    url.toString(),
                    loadingBuilder: (_, child, progress) => progress == null
                        ? child
                        : const CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                  ),
          ),
        ),
      );
    } else {
      body = Stack(
        children: [
          WebViewWidget(controller: _web!),
          if (_loading) const Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)),
        ],
      );
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  GlassIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (url != null)
                    GlassIconButton(
                      icon: Icons.open_in_new_rounded,
                      tooltip: 'Open in another app',
                      onPressed: () => launchUrl(url, mode: LaunchMode.externalApplication),
                    )
                  else
                    const SizedBox(width: 44),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: GlassPanel(
                  radius: 24,
                  padding: EdgeInsets.zero,
                  floating: false,
                  child: ClipRRect(borderRadius: BorderRadius.circular(24), child: body),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A file's name as people should see it: no storage path or id in front.
String cleanFileName(String name) {
  var n = name.split('/').last.split('?').first;
  n = Uri.decodeComponent(n);
  // Drop a leading id such as "0193f4c2-…-9a1b_" or a long hex prefix.
  n = n.replaceFirst(RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[_-]?'), '');
  n = n.replaceFirst(RegExp(r'^[0-9a-fA-F]{16,}[_-]'), '');
  return n.isEmpty ? 'File' : n;
}

/// A file shared in a session chat. The link needs the user's session, so
/// it's fetched through [download]. Pictures show in the chat (tap to zoom);
/// other files offer a download, saved where the user chooses.
class SecureAttachment extends StatefulWidget {
  const SecureAttachment({super.key, required this.name, required this.download, this.url, this.localPath});

  final String name;

  /// The server's link to the file, once it's stored.
  final String? url;

  /// The copy on this device, for a file the user just sent.
  final String? localPath;

  /// Fetches the file's bytes from [url] with the user's session.
  final Future<Uint8List> Function(String url) download;

  @override
  State<SecureAttachment> createState() => _SecureAttachmentState();
}

class _SecureAttachmentState extends State<SecureAttachment> {
  static final _cache = <String, Uint8List>{};

  Future<Uint8List?>? _bytes;
  bool _saving = false;
  bool _saved = false;
  String? _error;

  String get _name => cleanFileName(widget.name);
  bool get _image => isImageFile(_name);

  @override
  void initState() {
    super.initState();
    if (_image) _bytes = _load();
  }

  Future<Uint8List?> _load() async {
    final local = widget.localPath;
    if (local != null && File(local).existsSync()) return File(local).readAsBytes();
    final url = widget.url;
    if (url == null || url.isEmpty) return null;
    return _cache[url] ??= await widget.download(url);
  }

  Future<void> _openImage(Uint8List bytes) async {
    final file = File('${Directory.systemTemp.path}/chat_${_name.hashCode.abs()}_$_name');
    if (!file.existsSync()) await file.writeAsBytes(bytes);
    if (mounted) await openAttachment(context, name: _name, localPath: file.path);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final bytes = await _load();
      if (bytes == null) throw const FormatException();
      final path = await FilePicker.saveFile(fileName: _name, bytes: bytes, dialogTitle: 'Save file');
      if (mounted && path != null) setState(() => _saved = true);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn\'t download. Try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_image) {
      return FutureBuilder<Uint8List?>(
        future: _bytes,
        builder: (context, snap) {
          final bytes = snap.data;
          Widget box(Widget child) => ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(width: 220, height: 160, child: child),
          );
          if (bytes != null) {
            return Semantics(
              button: true,
              label: 'Picture $_name. Tap to view.',
              child: GestureDetector(
                onTap: () => _openImage(bytes),
                child: box(TrueColors(child: Image.memory(bytes, fit: BoxFit.cover))),
              ),
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return box(
              ColoredBox(
                color: AppColors.white(0.06),
                child: const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
              ),
            );
          }
          return _row(subtitle: 'Picture couldn\'t load');
        },
      );
    }
    return _row();
  }

  Widget _row({String? subtitle}) {
    final ext = _name.contains('.') ? _name.split('.').last.toUpperCase() : 'FILE';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(AttachmentPreview._iconFor(_name), size: 22, color: Colors.white),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.white),
              ),
              Text(_error ?? subtitle ?? (_saved ? 'Saved' : ext), style: AppText.caption.copyWith(fontSize: 11.5)),
            ],
          ),
        ),
        const SizedBox(width: 6),
        _saving
            ? const Padding(
                padding: EdgeInsets.all(10),
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
              )
            : IconButton(
                tooltip: 'Download',
                visualDensity: VisualDensity.compact,
                onPressed: (widget.url == null || widget.url!.isEmpty) && widget.localPath == null ? null : _save,
                icon: Icon(
                  _saved ? Icons.download_done_rounded : Icons.download_rounded,
                  size: 20,
                  color: Colors.white,
                ),
              ),
      ],
    );
  }
}
