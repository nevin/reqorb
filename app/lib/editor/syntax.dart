import 'package:flutter/material.dart';

/// The languages the editor can colour.
enum CodeLanguage {
  plain,
  json,
  graphql,
  xml,
  javascript,
  yaml,

  /// One `key=value` or `key: value` to a line, as variables and bulk
  /// edited headers are written.
  pairs,

  /// The checks and captures of the Tests tab, one to a line.
  checks,

  /// Code in a language of the C family, or near enough: comments open
  /// with `//`.
  source,

  /// Code in a scripting language: comments open with `#`.
  script;

  /// Whether this is code with brackets and quotes that come in pairs,
  /// rather than lines of plain words.
  bool get bracketed =>
      this != plain && this != pairs && this != checks && this != yaml;

  /// The language a body of the given content type is written in.
  static CodeLanguage ofContentType(String type) {
    final t = type.toLowerCase();
    if (t.contains('json')) return json;
    if (t.contains('graphql')) return graphql;
    if (t.contains('xml') || t.contains('html')) return xml;
    if (t.contains('javascript') || t.contains('ecmascript')) return javascript;
    if (t.contains('yaml')) return yaml;
    return plain;
  }

  /// The language a file is written in, by the end of its name.
  static CodeLanguage? ofFileName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return null;
    return switch (name.substring(dot + 1).toLowerCase()) {
      'json' || 'har' || 'geojson' || 'ipynb' => json,
      'xml' || 'html' || 'htm' || 'svg' || 'plist' || 'xsd' || 'wsdl' => xml,
      'js' || 'mjs' || 'cjs' || 'ts' || 'jsx' || 'tsx' => javascript,
      'yaml' || 'yml' => yaml,
      'graphql' || 'gql' => graphql,
      'env' || 'properties' || 'ini' => pairs,
      'c' ||
      'h' ||
      'cc' ||
      'cpp' ||
      'hpp' ||
      'cs' ||
      'java' ||
      'kt' ||
      'swift' ||
      'go' ||
      'rs' ||
      'dart' ||
      'scala' ||
      'proto' ||
      'css' ||
      'scss' => source,
      'py' ||
      'sh' ||
      'bash' ||
      'zsh' ||
      'rb' ||
      'pl' ||
      'toml' ||
      'r' ||
      'tf' ||
      'dockerfile' ||
      'mk' => script,
      'txt' || 'log' || 'md' || 'csv' || 'tsv' => plain,
      _ => null,
    };
  }

  /// What the language is called, for showing.
  String get label => switch (this) {
    plain => 'Plain text',
    json => 'JSON',
    graphql => 'GraphQL',
    xml => 'XML',
    javascript => 'JavaScript',
    yaml => 'YAML',
    pairs => 'Properties',
    checks => 'Checks',
    source => 'Source code',
    script => 'Script',
  };

  /// A guess from how the text starts, for a body nobody has labelled.
  static CodeLanguage sniff(String text) {
    final start = text.trimLeft();
    if (start.isEmpty) return plain;
    if (start.startsWith('<')) return xml;
    if (start.startsWith('{') || start.startsWith('[')) return json;
    return plain;
  }
}

/// What a stretch of code is, as far as colouring it goes.
enum TokenKind {
  key,
  string,
  number,
  keyword,
  comment,
  type,
  tag,
  attribute,
  parameter,

  /// A `{{name}}` placeholder, in any language.
  variable,
}

/// A coloured stretch of the text, from [start] up to [end].
class Token {
  const Token(this.start, this.end, this.kind);

  final int start;
  final int end;
  final TokenKind kind;

  @override
  String toString() => '$kind($start-$end)';
}

/// Colouring every token of a very large text would make typing slow.
const highlightLimit = 200 * 1024;

/// The colour a kind of token is shown in.
Color tokenColor(TokenKind kind, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return switch (kind) {
    TokenKind.key ||
    TokenKind.tag => dark ? const Color(0xFF9CC4FF) : const Color(0xFF0B63C5),
    TokenKind.string =>
      dark ? const Color(0xFF8FD6A4) : const Color(0xFF1A7F42),
    TokenKind.number || TokenKind.attribute =>
      dark ? const Color(0xFFE5B454) : const Color(0xFF9A6700),
    TokenKind.keyword =>
      dark ? const Color(0xFFD0A8FF) : const Color(0xFF6E43C9),
    TokenKind.comment =>
      dark ? const Color(0xFF8B949E) : const Color(0xFF6E7781),
    TokenKind.type => dark ? const Color(0xFF5CC8C2) : const Color(0xFF0F766E),
    TokenKind.parameter =>
      dark ? const Color(0xFFF2A0C8) : const Color(0xFFB0307A),
    TokenKind.variable =>
      dark ? const Color(0xFFFFA657) : const Color(0xFFB5560B),
  };
}

final _variable = RegExp(r'\{\{[^{}\n]*\}\}');

const _number = r'(?<![\w.])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?';

final _json = RegExp(
  r'("(?:[^"\\\n]|\\.)*"?)(?=(\s*:)?)'
  '|($_number)'
  r'|\b(true|false|null)\b',
);

final _graphql = RegExp(
  r'(#[^\n]*)'
  r'|("""[\s\S]*?(?:"""|$)|"(?:[^"\\\n]|\\.)*"?)'
  r'|(\$[A-Za-z_]\w*)'
  r'|(@[A-Za-z_]\w*)'
  '|($_number)'
  r'|([A-Za-z_]\w*)(?=(\s*:)?)',
);

const _graphqlKeywords = {
  'query',
  'mutation',
  'subscription',
  'fragment',
  'on',
  'true',
  'false',
  'null',
  'schema',
  'type',
  'input',
  'enum',
  'interface',
  'union',
  'scalar',
  'extend',
  'directive',
  'implements',
};

final _xml = RegExp(
  r'(<!--[\s\S]*?(?:-->|$))'
  r'|(<!\[CDATA\[[\s\S]*?(?:\]\]>|$))'
  r'|(<[/?!]?[A-Za-z_][\w:.-]*)',
);

final _xmlInTag = RegExp(
  r'''([A-Za-z_][\w:.-]*)(?=\s*=)|("[^"]*"?|'[^']*'?)|([/?]?>)|<''',
);

final _javascript = RegExp(
  r'(//[^\n]*|/\*[\s\S]*?(?:\*/|$))'
  r'''|("(?:[^"\\\n]|\\.)*"?|'(?:[^'\\\n]|\\.)*'?|`(?:[^`\\]|\\.)*`?)'''
  '|($_number)'
  r'|\b(const|let|var|function|return|if|else|for|while|do|switch|case|'
  r'break|continue|new|delete|typeof|instanceof|in|of|class|extends|import|'
  r'export|from|default|try|catch|finally|throw|async|await|yield|this|'
  r'super|true|false|null|undefined)\b',
);

/// The coloured stretches of [text], in order and never overlapping.
/// Anything not covered is shown plain.
List<Token> tokenize(String text, CodeLanguage language) {
  final tokens = switch (language) {
    CodeLanguage.plain => const <Token>[],
    CodeLanguage.json => _tokenizeJson(text),
    CodeLanguage.graphql => _tokenizeGraphql(text),
    CodeLanguage.xml => _tokenizeXml(text),
    CodeLanguage.javascript => _tokenizeJavascript(text),
    CodeLanguage.yaml => _tokenizeYaml(text),
    CodeLanguage.pairs => _tokenizePairs(text),
    CodeLanguage.checks => _tokenizeChecks(text),
    CodeLanguage.source => _tokenizeCode(text, _source),
    CodeLanguage.script => _tokenizeCode(text, _script),
  };
  return _withVariables(text, tokens);
}

List<Token> _tokenizeJson(String text) {
  final tokens = <Token>[];
  for (final m in _json.allMatches(text)) {
    final kind = m[1] != null
        ? (m[2] != null ? TokenKind.key : TokenKind.string)
        : m[3] != null
        ? TokenKind.number
        : TokenKind.keyword;
    tokens.add(Token(m.start, m.end, kind));
  }
  return tokens;
}

List<Token> _tokenizeGraphql(String text) {
  final tokens = <Token>[];
  for (final m in _graphql.allMatches(text)) {
    TokenKind? kind;
    if (m[1] != null) {
      kind = TokenKind.comment;
    } else if (m[2] != null) {
      kind = TokenKind.string;
    } else if (m[3] != null) {
      kind = TokenKind.parameter;
    } else if (m[4] != null) {
      kind = TokenKind.keyword;
    } else if (m[5] != null) {
      kind = TokenKind.number;
    } else if (m[6] case final name?) {
      if (m[7] != null) {
        // An argument or an alias: whatever stands before a colon.
        kind = TokenKind.key;
      } else if (_graphqlKeywords.contains(name)) {
        kind = TokenKind.keyword;
      } else if (name.codeUnitAt(0) < 0x5B && name.codeUnitAt(0) > 0x40) {
        kind = TokenKind.type;
      }
    }
    if (kind != null) tokens.add(Token(m.start, m.end, kind));
  }
  return tokens;
}

List<Token> _tokenizeXml(String text) {
  final tokens = <Token>[];
  var at = 0;
  while (at < text.length) {
    final m = _firstFrom(_xml, text, at);
    if (m == null) break;
    at = m.end;
    if (m[1] != null) {
      tokens.add(Token(m.start, m.end, TokenKind.comment));
      continue;
    }
    if (m[2] != null) {
      tokens.add(Token(m.start, m.end, TokenKind.string));
      continue;
    }
    tokens.add(Token(m.start, m.end, TokenKind.tag));
    // Inside the tag: attributes and their values, up to where it closes.
    while (at < text.length) {
      final inner = _firstFrom(_xmlInTag, text, at);
      if (inner == null) return tokens;
      if (inner[0] == '<') {
        // Another tag opened before this one closed.
        at = inner.start;
        break;
      }
      at = inner.end;
      if (inner[1] != null) {
        tokens.add(Token(inner.start, inner.end, TokenKind.attribute));
      } else if (inner[2] != null) {
        tokens.add(Token(inner.start, inner.end, TokenKind.string));
      } else {
        tokens.add(Token(inner.start, inner.end, TokenKind.tag));
        break;
      }
    }
  }
  return tokens;
}

List<Token> _tokenizeJavascript(String text) {
  final tokens = <Token>[];
  for (final m in _javascript.allMatches(text)) {
    final kind = m[1] != null
        ? TokenKind.comment
        : m[2] != null
        ? TokenKind.string
        : m[3] != null
        ? TokenKind.number
        : TokenKind.keyword;
    tokens.add(Token(m.start, m.end, kind));
  }
  return tokens;
}

final _yaml = RegExp(
  // A quoted string where a value or a key starts, so that the
  // apostrophe in plain words opens none; a key where a colon follows it.
  r'''((?<=(?:^|[:,\[{-])[ \t]*)(?:"(?:[^"\\\n]|\\.)*"?|'(?:[^'\n]|'')*'?))([ \t]*:(?=[ \t]|$))?'''
  // A comment, at the start of a line or after a space.
  r'|((?<=^|[ \t])#[^\n]*)'
  // A plain key, at the start of a line or of an item in a list.
  r'''|((?<=^[ \t]*(?:-[ \t]+)*)[^\s#"'{}\[\],:-][^\n:#]*?|(?<=^[ \t]*)-(?=\S)[^\n:#]*?)(?=[ \t]*:(?:[ \t]|$))'''
  // A value that is a number or a literal, and nothing else.
  r'|(?<=(?::|^[ \t]*-|^)[ \t]+)(true|false|null|~|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)(?=[ \t]*(?:#|$))',
  multiLine: true,
);

/// Where `key: |` or `key: >` starts a block of text: from the next line
/// to the last one indented further than the key.
final _blockStart = RegExp(
  r'^([ \t]*)(?:- )?[^\n#]*:[ \t]*[|>][-+0-9]*[ \t]*(?:#.*)?$',
);

/// The stretches of [text] that are blocks of text, which are not code.
List<(int, int)> _yamlBlocks(String text) {
  final blocks = <(int, int)>[];
  int? indent;
  var start = 0;
  var offset = 0;
  for (final line in text.split('\n')) {
    final end = offset + line.length;
    if (indent != null) {
      final own = line.length - line.trimLeft().length;
      if (line.trim().isNotEmpty && own <= indent) {
        blocks.add((start, offset));
        indent = null;
      }
    }
    if (indent == null) {
      if (_blockStart.firstMatch(line) case final m?) {
        indent = m[1]!.length;
        start = end + 1;
      }
    }
    offset = end + 1;
  }
  if (indent != null) blocks.add((start, text.length));
  return blocks;
}

List<Token> _tokenizeYaml(String text) {
  final tokens = <Token>[];
  final blocks = _yamlBlocks(text);
  var b = 0;
  for (final m in _yaml.allMatches(text)) {
    while (b < blocks.length && blocks[b].$2 <= m.start) {
      b++;
    }
    if (b < blocks.length && blocks[b].$1 <= m.start) continue;
    if (m[1] case final string?) {
      tokens.add(
        Token(
          m.start,
          m.start + string.length,
          m[2] != null ? TokenKind.key : TokenKind.string,
        ),
      );
    } else if (m[3] != null) {
      tokens.add(Token(m.start, m.end, TokenKind.comment));
    } else if (m[4] != null) {
      tokens.add(Token(m.start, m.end, TokenKind.key));
    } else if (m[5] case final value?) {
      final literal = RegExp(r'^(true|false|null|~)$').hasMatch(value);
      tokens.add(
        Token(m.start, m.end, literal ? TokenKind.keyword : TokenKind.number),
      );
    }
  }
  return tokens;
}

final _pairLine = RegExp(
  r'^[ \t]*(?:(#.*)|(?:(secret)[ \t]+)?([^\s=:#][^=:\n]*?)(?=[ \t]*[=:]))',
  multiLine: true,
);

List<Token> _tokenizePairs(String text) {
  final tokens = <Token>[];
  for (final m in _pairLine.allMatches(text)) {
    if (m[1] case final comment?) {
      tokens.add(Token(m.end - comment.length, m.end, TokenKind.comment));
      continue;
    }
    final key = m[3]!;
    if (m[2] != null) {
      final at = m.start + m[0]!.indexOf('secret');
      tokens.add(Token(at, at + 6, TokenKind.keyword));
    }
    tokens.add(Token(m.end - key.length, m.end, TokenKind.key));
  }
  return tokens;
}

final _checks = RegExp(
  r'("(?:[^"\\\n]|\\.)*"?)'
  '|($_number)'
  r'|(==|!=|<=|>=|<|>|\b(?:contains|exists|missing)\b)'
  r'|\b(status|time|size|header|body)\b',
);

List<Token> _tokenizeChecks(String text) {
  final tokens = <Token>[];
  for (final m in _checks.allMatches(text)) {
    final kind = m[1] != null
        ? TokenKind.string
        : m[2] != null
        ? TokenKind.number
        : m[3] != null
        ? TokenKind.keyword
        : TokenKind.type;
    tokens.add(Token(m.start, m.end, kind));
  }
  return tokens;
}

const _codeWords =
    r'\b(as|async|await|break|case|catch|class|const|def|defer|do|echo|else|'
    r'end|false|False|final|fn|for|from|fun|func|if|import|in|let|new|nil|'
    r'None|null|nullptr|package|print|public|puts|require|return|static|'
    r'struct|throws|true|True|try|use|using|val|var|void|while)\b';

/// Comment, string, number, keyword and, last, a name with a capital,
/// which in most languages is a type.
RegExp _codePattern(String comment, String strings) => RegExp(
  '($comment)'
  '|($strings)'
  '|($_number)'
  '|$_codeWords'
  r'|\b([A-Z][A-Za-z0-9_]*)\b',
);

final _source = _codePattern(
  r'//[^\n]*|/\*[\s\S]*?(?:\*/|$)',
  r'''"(?:[^"\\\n]|\\.)*"?|'(?:[^'\\\n]|\\.)*'?|`[^`]*`?''',
);

// Between single quotes a script's text may run over many lines, as a
// body does in a curl command; `\'` is how a shell writes a quote there.
final _script = _codePattern(
  r'#[^\n]*',
  r'''"(?:[^"\\\n]|\\.)*"?|\\'|'(?:[^'\\]|\\.)*'?''',
);

List<Token> _tokenizeCode(String text, RegExp pattern) {
  final tokens = <Token>[];
  for (final m in pattern.allMatches(text)) {
    final kind = m[1] != null
        ? TokenKind.comment
        : m[2] != null
        ? TokenKind.string
        : m[3] != null
        ? TokenKind.number
        : m[4] != null
        ? TokenKind.keyword
        : TokenKind.type;
    tokens.add(Token(m.start, m.end, kind));
  }
  return tokens;
}

RegExpMatch? _firstFrom(RegExp pattern, String text, int start) {
  final matches = pattern.allMatches(text, start).iterator;
  return matches.moveNext() ? matches.current : null;
}

/// Lays `{{placeholders}}` over [tokens], cutting whatever they sit in.
List<Token> _withVariables(String text, List<Token> tokens) {
  if (!text.contains('{{')) return tokens;
  final variables = [
    for (final m in _variable.allMatches(text))
      Token(m.start, m.end, TokenKind.variable),
  ];
  if (variables.isEmpty) return tokens;

  final merged = <Token>[];
  var v = 0;
  for (final token in tokens) {
    var start = token.start;
    // A placeholder may have run past the end of the token before.
    if (merged.isNotEmpty && merged.last.end > start) start = merged.last.end;
    if (start >= token.end) continue;
    // Placeholders wholly before this token.
    while (v < variables.length && variables[v].end <= start) {
      merged.add(variables[v++]);
    }
    // Placeholders that overlap it take their part of it.
    while (v < variables.length && variables[v].start < token.end) {
      final variable = variables[v];
      if (variable.start > start) {
        merged.add(Token(start, variable.start, token.kind));
      }
      merged.add(variable);
      start = variable.end;
      v++;
    }
    if (start < token.end) merged.add(Token(start, token.end, token.kind));
  }
  merged.addAll(variables.skip(v));
  return merged;
}
