import 'package:reqorb/editor/code_editor.dart';
import 'package:reqorb/src/rust/api/core.dart';

final _types = Expando<Map<String, GraphQlType>>();

Map<String, GraphQlType> _typesOf(GraphQlSchema schema) =>
    _types[schema] ??= {for (final type in schema.types) type.name: type};

final _token = RegExp(
  r'#[^\n]*'
  r'|"""[\s\S]*?(?:"""|$)|"(?:[^"\\\n]|\\.)*"?'
  r'|\.\.\.'
  r'|[A-Za-z_]\w*'
  r'|[{}():$@]',
);

final _nameChar = RegExp(r'\w');

/// What [schema] allows at [caret] in the query [text]: the fields of the
/// type being selected from, or the arguments of the field being called.
/// Unless [asked], nothing is offered before a letter has been typed.
Suggestions? completeGraphql(
  GraphQlSchema schema,
  String text,
  int caret, {
  required bool asked,
}) {
  var start = caret;
  while (start > 0 && _nameChar.hasMatch(text[start - 1])) {
    start--;
  }
  final typed = text.substring(start, caret).toLowerCase();
  if (typed.isEmpty && !asked) return null;

  final types = _typesOf(schema);
  // The type each open selection set selects from; null when unknown.
  final stack = <String?>[];
  // The type the next `{` opens.
  String? next = schema.queryType;
  // The field last named, whose arguments a `(` would open.
  GraphQlField? field;
  GraphQlField? called;
  var parens = 0;
  var afterOn = false;
  var last = '';

  for (final match in _token.allMatches(text.substring(0, start))) {
    final token = match[0]!;
    final first = token[0];
    if (first == '#' || first == '"') continue;
    switch (token) {
      case '(':
        if (parens == 0) called = field;
        parens++;
      case ')':
        if (parens > 0) parens--;
        if (parens == 0) called = null;
      case '{':
        if (parens == 0) {
          stack.add(next);
          next = null;
          field = null;
        }
      case '}':
        if (parens == 0) {
          if (stack.isNotEmpty) stack.removeLast();
          field = null;
          if (stack.isEmpty) next = schema.queryType;
        }
      case ':' || r'$' || '@' || '...':
        break;
      default:
        if (parens > 0) break;
        if (afterOn) {
          // `... on Type` or `fragment Name on Type`.
          next = token;
          afterOn = false;
        } else if (token == 'on') {
          afterOn = true;
        } else if (stack.isEmpty) {
          next = switch (token) {
            'query' => schema.queryType,
            'mutation' => schema.mutationType,
            'subscription' => schema.subscriptionType,
            _ => next,
          };
        } else if (last != r'$' && last != '@') {
          field = types[stack.last]?.fields
              .where((f) => f.name == token)
              .firstOrNull;
          next = field?.namedType;
        }
    }
    last = token;
  }
  // A variable or a directive is being named, not a field.
  if (last == r'$' || last == '@') return null;

  final items = <Suggestion>[];
  if (parens > 0) {
    // A value is being written, not an argument's name.
    if (called == null || last == ':') return null;
    for (final arg in called.args) {
      items.add((
        label: arg.name,
        insert: '${arg.name}: ',
        detail: arg.typeName,
      ));
    }
  } else if (stack.isEmpty) {
    for (final word in const [
      'query',
      'mutation',
      'subscription',
      'fragment',
    ]) {
      items.add((label: word, insert: word, detail: 'operation'));
    }
  } else {
    final type = types[stack.last];
    if (type == null) return null;
    for (final f in type.fields) {
      items.add((
        label: f.name,
        insert: f.name,
        detail: f.deprecated ? '${f.typeName} · deprecated' : f.typeName,
      ));
    }
    for (final member in type.members) {
      items.add((
        label: '... on $member',
        insert: '... on $member',
        detail: 'type',
      ));
    }
    items.add((label: '__typename', insert: '__typename', detail: 'String!'));
  }

  bool starts(Suggestion s) => s.label.toLowerCase().startsWith(typed);
  final matching = [
    ...items.where(starts),
    ...items.where((s) => !starts(s) && s.label.toLowerCase().contains(typed)),
  ];
  return matching.isEmpty ? null : (start: start, items: matching);
}
