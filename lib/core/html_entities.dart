// Character references (&amp;, &#39;, &rsquo;, …) back to the characters they stand for.

const _named = {
  'nbsp': ' ',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': '\'',
  'rsquo': '’',
  'lsquo': '‘',
  'rdquo': '”',
  'ldquo': '“',
  'ndash': '–',
  'mdash': '—',
  'hellip': '…',
  'bull': '•',
  'middot': '·',
  'copy': '©',
  'reg': '®',
  'trade': '™',
  'laquo': '«',
  'raquo': '»',
  'euro': '€',
  'pound': '£',
  'yen': '¥',
  'rupee': '₹',
  'times': '×',
  'divide': '÷',
  'deg': '°',
  'amp': '&',
};
final _entity = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');

/// Decodes character references: named ones like &rsquo; and numbered ones
/// like &#39; or &#x2019;. Unknown names are left as written. The server
/// stores user text HTML-escaped, so it goes through this before display.
String decodeHtmlEntities(String s) => s.replaceAllMapped(_entity, (m) {
  final ref = m.group(1)!;
  if (ref.startsWith('#')) {
    final code = ref.startsWith('#x') || ref.startsWith('#X')
        ? int.tryParse(ref.substring(2), radix: 16)
        : int.tryParse(ref.substring(1));
    return code == null || code <= 0 || code > 0x10FFFF ? m.group(0)! : String.fromCharCode(code);
  }
  return _named[ref.toLowerCase()] ?? m.group(0)!;
});
