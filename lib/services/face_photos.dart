import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// Face photos are made small before upload: phone cameras save them far
/// larger than the face checks accept (each photo at most 500 KB, a submit at
/// most 2.5 MB).
abstract final class FacePhotos {
  /// Widest a photo is sent at, in pixels.
  static const maxWidth = 640;
  static const maxPhotoBytes = 500 * 1024;
  static const maxTotalBytes = (2.5 * 1024 * 1024) ~/ 1;
  static const maxPhotos = 20;

  /// Which of [count] photos to send: all of them, or [maxPhotos] evenly
  /// spaced when there are more.
  static List<int> keep(int count) => count <= maxPhotos
      ? [for (var i = 0; i < count; i++) i]
      : [for (var i = 0; i < maxPhotos; i++) (i * (count - 1) / (maxPhotos - 1)).round()];

  /// Copies of [paths] at most [maxWidth] wide (never enlarged), as JPEG,
  /// within the size limits. Decoding runs in the engine and encoding off the
  /// UI thread, so the screen doesn't freeze.
  static Future<List<String>> prepare(List<String> paths) async {
    final frames = [for (final path in paths) await _decode(path)];
    final dir = await Directory.systemTemp.createTemp('face_');
    // A lower quality only if the usual one doesn't fit.
    var out = <String>[];
    for (final quality in const [82, 70, 60]) {
      out = [];
      var total = 0;
      var fits = true;
      // One background isolate encodes them all.
      final jpegs = await Isolate.run(() => [for (final f in frames) _encode(f, quality)]);
      for (final (i, jpeg) in jpegs.indexed) {
        total += jpeg.length;
        if (jpeg.length > maxPhotoBytes) fits = false;
        final file = File('${dir.path}/frame_$i.jpg');
        await file.writeAsBytes(jpeg, flush: true);
        out.add(file.path);
      }
      if (fits && total <= maxTotalBytes) break;
    }
    return out;
  }

  /// The photo upright (as the phone took it), at most [maxWidth] on its
  /// longer side, as raw RGBA.
  static Future<({int width, int height, Uint8List rgba})> _decode(String path) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(await File(path).readAsBytes());
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) {
        // Both sides are kept within the limit, so the width is too however
        // the photo is turned.
        final longer = width > height ? width : height;
        if (longer <= maxWidth) return ui.TargetImageSize(width: width, height: height);
        return ui.TargetImageSize(
          width: (width * maxWidth / longer).round(),
          height: (height * maxWidth / longer).round(),
        );
      },
    );
    final image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    // Copied out of the engine's buffer so it can go to the background isolate.
    final frame = (width: image.width, height: image.height, rgba: Uint8List.fromList(data!.buffer.asUint8List()));
    image.dispose();
    codec.dispose();
    return frame;
  }

  static Uint8List _encode(({int width, int height, Uint8List rgba}) f, int quality) => img.encodeJpg(
    img.Image.fromBytes(width: f.width, height: f.height, bytes: f.rgba.buffer, numChannels: 4),
    quality: quality,
  );
}
