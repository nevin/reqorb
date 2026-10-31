//! Where a document's strings, comments and tags are, as far as matching
//! brackets and colouring part of it need to know: a scan of bytes, by
//! the same rules as the app's colouring, that tells code from what is
//! quoted, and what a stretch of text starts inside.
//!
//! Every byte that opens or closes something here is ASCII, so the scan
//! goes byte by byte and never mistakes part of a character for one.

/// How a language quotes text and writes comments.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Quoting {
    /// Strings in double quotes, on one line.
    Json,
    /// JavaScript: `//` and `/* */` comments; strings in single or double
    /// quotes on one line, or in backquotes over lines.
    JavaScript,
    /// Code of the C family: as JavaScript, though a backquote's string
    /// takes no escapes.
    Source,
    /// A scripting language: `#` comments; strings in double quotes on
    /// one line, or in single quotes over lines, where `\'` is a quote.
    Script,
    /// GraphQL: `#` comments; strings in double quotes on one line, or in
    /// three of them over lines.
    Graphql,
    /// XML and HTML: `<!-- -->` comments, CDATA sections, and tags, whose
    /// attributes' values are quoted.
    Xml,
}

/// What a byte of the text is inside.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Inside {
    Code,
    LineComment,
    BlockComment,
    /// A string on one line, closed by this quote.
    String(u8),
    /// A string in backquotes, over lines.
    Template,
    /// A script's string in single quotes, over lines.
    ScriptString,
    /// GraphQL's string in three double quotes.
    BlockString,
    XmlComment,
    Cdata,
    /// A tag, between its name and the `>` that closes it.
    Tag,
    /// A tag's attribute value, closed by this quote.
    Attribute(u8),
}

impl Inside {
    /// What, put before a stretch of text, has the app colour it as if it
    /// started here: the opening of the string or comment it is inside.
    pub fn opener(self, quoting: Quoting) -> &'static str {
        match self {
            Inside::Code => "",
            Inside::LineComment => match quoting {
                Quoting::Script | Quoting::Graphql => "#",
                _ => "//",
            },
            Inside::BlockComment => "/*",
            Inside::String(b'\'') => "'",
            Inside::String(_) => "\"",
            Inside::Template => "`",
            Inside::ScriptString => "'",
            Inside::BlockString => "\"\"\"",
            Inside::XmlComment => "<!--",
            Inside::Cdata => "<![CDATA[",
            Inside::Tag => "<a ",
            Inside::Attribute(b'\'') => "<a b='",
            Inside::Attribute(_) => "<a b=\"",
        }
    }
}

/// Goes through `bytes` from `inside`, calling `bracket` with the place of
/// every bracket in code, and gives what the end is inside.
pub fn scan(
    bytes: &[u8],
    quoting: Quoting,
    mut inside: Inside,
    mut bracket: impl FnMut(usize, u8),
) -> Inside {
    let at = |i: usize, s: &[u8]| bytes[i..].starts_with(s);
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        match inside {
            Inside::Code | Inside::Tag => {
                if matches!(b, b'{' | b'}' | b'[' | b']' | b'(' | b')') {
                    bracket(i, b);
                    i += 1;
                    continue;
                }
                let (next, step) = opens(bytes, i, quoting, inside);
                inside = next;
                i += step;
            }
            Inside::LineComment => {
                if b == b'\n' {
                    inside = Inside::Code;
                }
                i += 1;
            }
            Inside::BlockComment => {
                if at(i, b"*/") {
                    inside = Inside::Code;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            Inside::String(quote) => {
                if b == b'\\' && bytes.get(i + 1).is_some_and(|&n| n != b'\n') {
                    i += 2;
                    continue;
                }
                // A string left open ends with its line.
                if b == quote || b == b'\n' {
                    inside = Inside::Code;
                }
                i += 1;
            }
            Inside::Template => {
                if b == b'\\' && quoting == Quoting::JavaScript {
                    i += 2;
                    continue;
                }
                if b == b'`' {
                    inside = Inside::Code;
                }
                i += 1;
            }
            Inside::ScriptString => {
                if b == b'\\' {
                    i += 2;
                    continue;
                }
                if b == b'\'' {
                    inside = Inside::Code;
                }
                i += 1;
            }
            Inside::BlockString => {
                if at(i, b"\"\"\"") {
                    inside = Inside::Code;
                    i += 3;
                } else {
                    i += 1;
                }
            }
            Inside::XmlComment => {
                if at(i, b"-->") {
                    inside = Inside::Code;
                    i += 3;
                } else {
                    i += 1;
                }
            }
            Inside::Cdata => {
                if at(i, b"]]>") {
                    inside = Inside::Code;
                    i += 3;
                } else {
                    i += 1;
                }
            }
            Inside::Attribute(quote) => {
                if b == quote {
                    inside = Inside::Tag;
                }
                i += 1;
            }
        }
    }
    inside
}

/// What starts at `i` in code, or in a tag, and how many bytes it takes.
fn opens(bytes: &[u8], i: usize, quoting: Quoting, inside: Inside) -> (Inside, usize) {
    let at = |s: &[u8]| bytes[i..].starts_with(s);
    let b = bytes[i];
    if inside == Inside::Tag {
        return match b {
            b'"' | b'\'' => (Inside::Attribute(b), 1),
            b'>' => (Inside::Code, 1),
            // Another tag opened before this one closed: taken from here
            // as code.
            b'<' => opens(bytes, i, quoting, Inside::Code),
            _ => (Inside::Tag, 1),
        };
    }
    match quoting {
        Quoting::Json => match b {
            b'"' => (Inside::String(b'"'), 1),
            _ => (Inside::Code, 1),
        },
        Quoting::JavaScript | Quoting::Source => {
            if at(b"//") {
                (Inside::LineComment, 2)
            } else if at(b"/*") {
                (Inside::BlockComment, 2)
            } else {
                match b {
                    b'"' | b'\'' => (Inside::String(b), 1),
                    b'`' => (Inside::Template, 1),
                    _ => (Inside::Code, 1),
                }
            }
        }
        Quoting::Script => match b {
            b'#' => (Inside::LineComment, 1),
            b'"' => (Inside::String(b'"'), 1),
            // How a shell writes a quote outside quotes.
            b'\\' if bytes.get(i + 1) == Some(&b'\'') => (Inside::Code, 2),
            b'\'' => (Inside::ScriptString, 1),
            _ => (Inside::Code, 1),
        },
        Quoting::Graphql => {
            if at(b"\"\"\"") {
                (Inside::BlockString, 3)
            } else {
                match b {
                    b'#' => (Inside::LineComment, 1),
                    b'"' => (Inside::String(b'"'), 1),
                    _ => (Inside::Code, 1),
                }
            }
        }
        Quoting::Xml => {
            if at(b"<!--") {
                (Inside::XmlComment, 4)
            } else if at(b"<![CDATA[") {
                (Inside::Cdata, 9)
            } else if b == b'<' && starts_tag(&bytes[i + 1..]) {
                (Inside::Tag, 1)
            } else {
                (Inside::Code, 1)
            }
        }
    }
}

/// Whether what follows a `<` is a tag's name, perhaps after `/`, `?` or
/// `!`.
fn starts_tag(after: &[u8]) -> bool {
    let name = match after.first() {
        Some(b'/' | b'?' | b'!') => &after[1..],
        _ => after,
    };
    name.first()
        .is_some_and(|&c| c.is_ascii_alphabetic() || c == b'_')
}

/// The bracket at `at`, or just before it, and its partner, in `bytes`,
/// which are scanned from their start in code. Both are given as places
/// in `bytes`, the opening one first. The bracket before `at`, the one
/// just typed, is looked at first; none when neither is a bracket in code,
/// or its partner is not in `bytes`.
pub fn bracket_pair(bytes: &[u8], at: usize, quoting: Quoting) -> Option<(usize, usize)> {
    let is_bracket = |i: usize| {
        bytes
            .get(i)
            .is_some_and(|b| matches!(b, b'{' | b'}' | b'[' | b']' | b'(' | b')'))
    };
    let near = [at.checked_sub(1), Some(at)];
    if !near.iter().flatten().any(|&i| is_bracket(i)) {
        return None;
    }
    let mut found = Vec::new();
    scan(bytes, quoting, Inside::Code, |i, b| found.push((i, b)));
    for i in near.into_iter().flatten() {
        let Ok(k) = found.binary_search_by_key(&i, |&(p, _)| p) else {
            continue;
        };
        let own = found[k].1;
        let (other, forward) = match own {
            b'{' => (b'}', true),
            b'[' => (b']', true),
            b'(' => (b')', true),
            b'}' => (b'{', false),
            b']' => (b'[', false),
            _ => (b'(', false),
        };
        let mut depth = 0i64;
        let mut step = |j: usize| {
            let b = found[j].1;
            if b == own {
                depth += 1;
            } else if b == other {
                depth -= 1;
            }
            depth == 0
        };
        let partner = if forward {
            (k..found.len()).find(|&j| step(j))
        } else {
            (0..=k).rev().find(|&j| step(j))
        };
        return partner.map(|j| {
            let (a, b) = (found[k].0, found[j].0);
            (a.min(b), a.max(b))
        });
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair(text: &str, at: usize, quoting: Quoting) -> Option<(usize, usize)> {
        bracket_pair(text.as_bytes(), at, quoting)
    }

    fn end(text: &str, quoting: Quoting) -> Inside {
        scan(text.as_bytes(), quoting, Inside::Code, |_, _| {})
    }

    #[test]
    fn brackets_pair_across_lines_and_nesting() {
        let text = "{\n  \"a\": [1, {\"b\": 2}],\n  \"c\": 3\n}";
        // After the opening brace, and before the closing one.
        assert_eq!(pair(text, 1, Quoting::Json), Some((0, text.len() - 1)));
        assert_eq!(
            pair(text, text.len() - 1, Quoting::Json),
            Some((0, text.len() - 1))
        );
        let open = text.find('[').unwrap();
        let close = text.find(']').unwrap();
        assert_eq!(pair(text, open, Quoting::Json), Some((open, close)));
        // Next to no bracket.
        assert_eq!(pair(text, 4, Quoting::Json), None);
    }

    #[test]
    fn the_bracket_just_typed_comes_first() {
        // Between `(` and `)`: the one before the caret is matched.
        assert_eq!(pair("f(x)()", 5, Quoting::JavaScript), Some((4, 5)));
        assert_eq!(pair("f()", 2, Quoting::JavaScript), Some((1, 2)));
    }

    #[test]
    fn quoted_brackets_do_not_count() {
        let text = r#"{"a": "}", "b": "{\"}"}"#;
        assert_eq!(pair(text, 0, Quoting::Json), Some((0, text.len() - 1)));
        // A bracket in a string has no partner.
        let quoted = text.find('}').unwrap();
        assert_eq!(pair(text, quoted, Quoting::Json), None);

        let js = "f(/* ) */ ')', `\n)`, // )\n x)";
        assert_eq!(pair(js, 1, Quoting::JavaScript), Some((1, js.len() - 1)));
    }

    #[test]
    fn an_unmatched_bracket_has_no_partner() {
        // Only brackets of its own kind are counted, as the app does.
        assert_eq!(pair("{[}", 1, Quoting::Json), Some((0, 2)));
        assert_eq!(pair("{[}", 2, Quoting::Json), None);
        assert_eq!(pair("(((", 0, Quoting::Source), None);
    }

    #[test]
    fn what_the_end_is_inside() {
        assert_eq!(end("a /* b", Quoting::JavaScript), Inside::BlockComment);
        assert_eq!(end("a /* b */ c", Quoting::JavaScript), Inside::Code);
        assert_eq!(end("x = `a\nb", Quoting::JavaScript), Inside::Template);
        // A string on one line ends with it, closed or not.
        assert_eq!(end("\"a\nb", Quoting::Json), Inside::Code);
        assert_eq!(end("\"a\\\"", Quoting::Json), Inside::String(b'"'));
        assert_eq!(end("echo 'a\nb", Quoting::Script), Inside::ScriptString);
        assert_eq!(end("echo \\'a", Quoting::Script), Inside::Code);
        assert_eq!(end("\"\"\"doc\n", Quoting::Graphql), Inside::BlockString);
        assert_eq!(end("# (\n", Quoting::Graphql), Inside::Code);
        assert_eq!(end("<a href=\"x\n", Quoting::Xml), Inside::Attribute(b'"'));
        assert_eq!(end("<a\n  b=1", Quoting::Xml), Inside::Tag);
        assert_eq!(end("<a> 1 < 2", Quoting::Xml), Inside::Code);
        assert_eq!(end("<!-- <a", Quoting::Xml), Inside::XmlComment);
        assert_eq!(end("<![CDATA[ <", Quoting::Xml), Inside::Cdata);
    }

    #[test]
    fn a_tag_opened_in_a_tag_starts_again() {
        assert_eq!(end("<a <!-- x", Quoting::Xml), Inside::XmlComment);
    }
}
