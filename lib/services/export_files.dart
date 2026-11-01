import 'dart:convert';
import 'dart:typed_data';

/// A titled table for export.
class ExportTable {
  const ExportTable({required this.title, required this.headers, required this.rows});

  final String title;
  final List<String> headers;
  final List<List<String>> rows;
}

/// Builds an Excel workbook (SpreadsheetML), one sheet per table. Excel and
/// most spreadsheet apps open it directly.
Uint8List buildExcel(List<ExportTable> tables) {
  String esc(String v) =>
      v.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<?mso-application progid="Excel.Sheet"?>')
    ..writeln(
      '<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" '
      'xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">',
    )
    ..writeln('<Styles><Style ss:ID="h"><Font ss:Bold="1"/></Style></Styles>');
  for (final table in tables) {
    final name = table.title.replaceAll(RegExp(r'[\\/?*\[\]:]'), ' ');
    out.writeln('<Worksheet ss:Name="${esc(name.length > 31 ? name.substring(0, 31) : name)}"><Table>');
    out.write('<Row>');
    for (final h in table.headers) {
      out.write('<Cell ss:StyleID="h"><Data ss:Type="String">${esc(h)}</Data></Cell>');
    }
    out.writeln('</Row>');
    for (final row in table.rows) {
      out.write('<Row>');
      for (final cell in row) {
        final number = RegExp(r'^-?\d+$').hasMatch(cell);
        out.write('<Cell><Data ss:Type="${number ? 'Number' : 'String'}">${esc(cell)}</Data></Cell>');
      }
      out.writeln('</Row>');
    }
    out.writeln('</Table></Worksheet>');
  }
  out.writeln('</Workbook>');
  return Uint8List.fromList(utf8.encode(out.toString()));
}

/// Builds a simple A4 text PDF: a heading, then each table as aligned text,
/// flowing onto new pages as needed. Uses the built-in Courier font, so ₹
/// is written as "Rs.".
Uint8List buildPdf(String heading, List<String> subtitle, List<ExportTable> tables) {
  const perPage = 58;
  String clean(String v) => v.replaceAll('₹', 'Rs.').replaceAll(RegExp(r'[^\x20-\x7E]'), '?');
  String fit(String v, int width) {
    final c = clean(v);
    return c.length > width ? '${c.substring(0, width - 1)}~' : c.padRight(width);
  }

  final lines = <(String, bool)>[(heading, true), for (final s in subtitle) (s, false), ('', false)];
  for (final table in tables) {
    lines.add((table.title, true));
    // Column widths from content, capped so a row fits the page (~92 chars).
    final widths = [
      for (var c = 0; c < table.headers.length; c++)
        [table.headers[c].length, for (final r in table.rows) clean(r[c]).length].reduce((a, b) => a > b ? a : b),
    ];
    var total = widths.fold(0, (s, w) => s + w + 2);
    while (total > 92) {
      final widest = widths.indexOf(widths.reduce((a, b) => a > b ? a : b));
      widths[widest]--;
      total--;
    }
    String row(List<String> cells) => [for (var c = 0; c < cells.length; c++) fit(cells[c], widths[c])].join('  ');
    lines
      ..add((row(table.headers), true))
      ..add(('-' * total.clamp(0, 92), false));
    if (table.rows.isEmpty) lines.add(('No records for this range.', false));
    for (final r in table.rows) {
      lines.add((row(r), false));
    }
    lines.add(('', false));
  }

  final pages = <List<(String, bool)>>[
    for (var i = 0; i < lines.length; i += perPage) lines.sublist(i, (i + perPage).clamp(0, lines.length)),
  ];
  String esc(String v) => clean(v).replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');

  // Objects: 1 catalog, 2 pages, 3 regular font, 4 bold font, then a page and
  // its content stream per page.
  final objects = <String>[];
  final kids = [for (var p = 0; p < pages.length; p++) '${5 + p * 2} 0 R'].join(' ');
  objects
    ..add('<< /Type /Catalog /Pages 2 0 R >>')
    ..add('<< /Type /Pages /Kids [$kids] /Count ${pages.length} >>')
    ..add('<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>')
    ..add('<< /Type /Font /Subtype /Type1 /BaseFont /Courier-Bold >>');
  for (var p = 0; p < pages.length; p++) {
    final content = StringBuffer('BT\n');
    var y = 800;
    for (final (text, bold) in pages[p]) {
      content.writeln('/${bold ? 'F2' : 'F1'} 9 Tf 1 0 0 1 36 $y Tm (${esc(text)}) Tj');
      y -= 13;
    }
    content.writeln('/F1 8 Tf 1 0 0 1 36 30 Tm (Page ${p + 1} of ${pages.length}) Tj\nET');
    final stream = content.toString();
    objects
      ..add(
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] '
        '/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents ${6 + p * 2} 0 R >>',
      )
      ..add('<< /Length ${latin1.encode(stream).length} >>\nstream\n${stream}endstream');
  }

  final out = BytesBuilder();
  void write(String s) => out.add(latin1.encode(s));
  write('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return out.toBytes();
}
