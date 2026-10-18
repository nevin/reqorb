//! JSON in a document of any size, without parsing it whole: the children
//! of one object or array at a time, for a tree that opens as it is
//! explored, and the whole of it written out again indented or minified,
//! a megabyte at a time.

use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};

use memchr::memchr2;

use super::text::Text;
use crate::Error;

/// How much is read from the document at once.
const BUFFER: u64 = 1024 * 1024;

/// The most bytes of a value or key shown before it is cut short.
const PREVIEW: usize = 120;

/// What a JSON value is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JsonKind {
    Object,
    Array,
    String,
    Number,
    Bool,
    Null,
}

/// One value in a document's JSON, as a tree shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonNode {
    /// Its name in the object it is in; none in an array, or at the top.
    pub key: Option<String>,
    pub kind: JsonKind,
    /// The start of a string, number, `true`, `false` or `null`, as
    /// written; empty for an object or array.
    pub preview: String,
    /// Where it is, as bytes, from its first character to after its last.
    pub start: u64,
    pub end: u64,
}

/// Some of the children of an object or array.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct JsonPage {
    pub nodes: Vec<JsonNode>,
    /// Where to go on from for the rest; none when there are no more.
    pub next: Option<u64>,
}

/// Reads a document forward a buffer at a time.
struct Reader<'a> {
    text: &'a Text,
    buf: Vec<u8>,
    /// Where `buf` starts in the document.
    from: u64,
    at: u64,
}

impl<'a> Reader<'a> {
    fn new(text: &'a Text, at: u64) -> Self {
        Self {
            text,
            buf: Vec::new(),
            from: at,
            at,
        }
    }

    fn peek(&mut self) -> Option<u8> {
        let i = self.at.checked_sub(self.from)?;
        if i < self.buf.len() as u64 {
            return Some(self.buf[i as usize]);
        }
        if self.at >= self.text.len() {
            return None;
        }
        self.from = self.at;
        self.buf = self
            .text
            .read(self.at, (self.at + BUFFER).min(self.text.len()));
        self.buf.first().copied()
    }

    fn next(&mut self) -> Option<u8> {
        let byte = self.peek()?;
        self.at += 1;
        Some(byte)
    }

    fn skip_space(&mut self) {
        while let Some(b' ' | b'\t' | b'\n' | b'\r') = self.peek() {
            self.at += 1;
        }
    }

    fn fail(&self, what: &str) -> Error {
        let line = self.text.newlines_before(self.at.min(self.text.len())) + 1;
        Error::Format(format!("not valid JSON at line {line}: {what}"))
    }

    /// The bytes from the reader on, as many as are at hand, reading more
    /// when there are none; empty at the end.
    fn rest(&mut self) -> &[u8] {
        if self.peek().is_none() {
            return &[];
        }
        &self.buf[(self.at - self.from) as usize..]
    }

    /// Passes over a string whose opening quote has been read, keeping
    /// up to [`PREVIEW`] bytes of it.
    fn string(&mut self, keep: &mut Vec<u8>) -> Result<(), Error> {
        let mut escaped = false;
        loop {
            let rest = self.rest();
            if rest.is_empty() {
                return Err(self.fail("a string is not closed"));
            }
            let mut i = 0;
            if escaped {
                // The character after a backslash that ended the last read.
                i = 1;
                escaped = false;
            }
            loop {
                match memchr2(b'"', b'\\', &rest[i..]) {
                    None => {
                        i = rest.len();
                        break;
                    }
                    Some(k) if rest[i + k] == b'"' => {
                        let end = i + k;
                        if keep.len() < PREVIEW {
                            let take = (PREVIEW - keep.len()).min(end);
                            keep.extend_from_slice(&rest[..take]);
                        }
                        self.at += end as u64 + 1;
                        return Ok(());
                    }
                    Some(k) => {
                        i += k + 2;
                        if i > rest.len() {
                            escaped = true;
                            i = rest.len();
                            break;
                        }
                    }
                }
            }
            if keep.len() < PREVIEW {
                let take = (PREVIEW - keep.len()).min(i);
                keep.extend_from_slice(&rest[..take]);
            }
            self.at += i as u64;
        }
    }

    /// Passes over a value, keeping the start of a scalar.
    fn value(&mut self, keep: &mut Vec<u8>) -> Result<JsonKind, Error> {
        self.skip_space();
        match self.next() {
            None => Err(self.fail("a value is missing")),
            Some(b'"') => {
                self.string(keep)?;
                Ok(JsonKind::String)
            }
            Some(open @ (b'{' | b'[')) => {
                self.container()?;
                Ok(if open == b'{' {
                    JsonKind::Object
                } else {
                    JsonKind::Array
                })
            }
            Some(first) => {
                let kind = match first {
                    b't' | b'f' => JsonKind::Bool,
                    b'n' => JsonKind::Null,
                    b'-' | b'0'..=b'9' => JsonKind::Number,
                    _ => return Err(self.fail("a value is not one JSON knows")),
                };
                keep.push(first);
                while let Some(byte) = self.peek() {
                    if !(byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'+' | b'-')) {
                        break;
                    }
                    if keep.len() < PREVIEW {
                        keep.push(byte);
                    }
                    self.at += 1;
                }
                Ok(kind)
            }
        }
    }

    /// Passes over the rest of an object or array whose opening bracket
    /// has been read.
    fn container(&mut self) -> Result<(), Error> {
        let mut depth = 1u32;
        let mut in_string = false;
        let mut escaped = false;
        loop {
            let rest = self.rest();
            if rest.is_empty() {
                return Err(self.fail("an object or array is not closed"));
            }
            let mut i = 0;
            while i < rest.len() {
                if in_string {
                    if escaped {
                        escaped = false;
                        i += 1;
                        continue;
                    }
                    match memchr2(b'"', b'\\', &rest[i..]) {
                        None => i = rest.len(),
                        Some(k) => {
                            i += k + 1;
                            if rest[i - 1] == b'\\' {
                                escaped = true;
                            } else {
                                in_string = false;
                            }
                        }
                    }
                    continue;
                }
                match rest[i] {
                    b'"' => in_string = true,
                    b'{' | b'[' => depth += 1,
                    b'}' | b']' => {
                        depth -= 1;
                        if depth == 0 {
                            self.at += i as u64 + 1;
                            return Ok(());
                        }
                    }
                    _ => {}
                }
                i += 1;
            }
            self.at += rest.len() as u64;
        }
    }
}

fn text_of(bytes: &[u8]) -> String {
    let mut end = bytes.len().min(PREVIEW);
    // Not through the middle of a character.
    while end > 0 && end < bytes.len() && (bytes[end] & 0xC0) == 0x80 {
        end -= 1;
    }
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

/// The value at the top of the document.
pub(super) fn root(text: &Text) -> Result<JsonNode, Error> {
    let mut reader = Reader::new(text, 0);
    reader.skip_space();
    // A byte order mark is not part of the JSON.
    if reader.peek() == Some(0xEF) {
        reader.at += 3;
        reader.skip_space();
    }
    let start = reader.at;
    let mut keep = Vec::new();
    let kind = reader.value(&mut keep)?;
    Ok(JsonNode {
        key: None,
        kind,
        preview: text_of(&keep),
        start,
        end: reader.at,
    })
}

/// Up to `count` children of the object or array at `at`, from its first,
/// or from `from`, where the page before left off.
pub(super) fn children(
    text: &Text,
    at: u64,
    from: Option<u64>,
    count: usize,
) -> Result<JsonPage, Error> {
    let mut reader = Reader::new(text, at);
    let object = match reader.next() {
        Some(b'{') => true,
        Some(b'[') => false,
        _ => return Err(reader.fail("there is no object or array here")),
    };
    let closer = if object { b'}' } else { b']' };
    if let Some(from) = from {
        reader.at = from;
    }
    let mut page = JsonPage::default();
    loop {
        reader.skip_space();
        if reader.peek() == Some(b',') {
            reader.at += 1;
            reader.skip_space();
        }
        match reader.peek() {
            None => return Err(reader.fail("an object or array is not closed")),
            Some(byte) if byte == closer => return Ok(page),
            Some(_) if page.nodes.len() >= count => {
                page.next = Some(reader.at);
                return Ok(page);
            }
            Some(_) => {}
        }
        let key = if object {
            if reader.next() != Some(b'"') {
                return Err(reader.fail("a name in an object is not in quotes"));
            }
            let mut name = Vec::new();
            reader.string(&mut name)?;
            reader.skip_space();
            if reader.next() != Some(b':') {
                return Err(reader.fail("a name in an object has no `:` after it"));
            }
            Some(text_of(&name))
        } else {
            None
        };
        reader.skip_space();
        let start = reader.at;
        let mut keep = Vec::new();
        let kind = reader.value(&mut keep)?;
        page.nodes.push(JsonNode {
            key,
            kind,
            preview: text_of(&keep),
            start,
            end: reader.at,
        });
    }
}

/// Writes all of `text`, which is JSON, to `out`: indented by `indent`, or
/// on one line with no spaces when there is none. Reports how far it has
/// read after each megabyte, and stops when `cancel` is set.
pub(super) fn format(
    text: &Text,
    indent: Option<&str>,
    out: &mut dyn Write,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(u64),
) -> Result<(), Error> {
    const CHUNK: u64 = 1024 * 1024;
    let failed = |e: std::io::Error| {
        Error::Io(format!(
            "the JSON could not be written: {}",
            crate::spill::io_problem(&e)
        ))
    };
    let mut out = std::io::BufWriter::with_capacity(256 * 1024, out);
    let mut stack: Vec<u8> = Vec::new();
    let mut in_string = false;
    let mut escaped = false;
    // An object or array opened with nothing in it yet: whether it is
    // empty is known only at what comes next.
    let mut opened = false;
    let mut line = 1u64;
    let mut seen_value = false;
    // In the middle of a number, `true`, `false` or `null`.
    let mut in_scalar = false;
    let newline = |out: &mut dyn Write, depth: usize| -> std::io::Result<()> {
        if let Some(unit) = indent {
            out.write_all(b"\n")?;
            for _ in 0..depth {
                out.write_all(unit.as_bytes())?;
            }
        }
        Ok(())
    };
    let invalid =
        |line: u64, what: &str| Error::Format(format!("not valid JSON at line {line}: {what}"));
    let len = text.len();
    let mut at = 0;
    while at < len {
        if cancel.load(Ordering::Relaxed) {
            return Err(Error::Cancelled);
        }
        let to = (at + CHUNK).min(len);
        let chunk = text.read(at, to);
        for &byte in &chunk {
            if byte == b'\n' {
                line += 1;
            }
            if in_string {
                out.write_all(&[byte]).map_err(failed)?;
                if escaped {
                    escaped = false;
                } else if byte == b'\\' {
                    escaped = true;
                } else if byte == b'"' {
                    in_string = false;
                }
                continue;
            }
            let scalar = in_scalar;
            in_scalar = false;
            match byte {
                b' ' | b'\t' | b'\n' | b'\r' => {}
                b'}' | b']' => {
                    let open = if byte == b'}' { b'{' } else { b'[' };
                    if stack.pop() != Some(open) {
                        return Err(invalid(line, "a closing bracket does not match"));
                    }
                    if !opened {
                        newline(&mut out, stack.len()).map_err(failed)?;
                    }
                    opened = false;
                    out.write_all(&[byte]).map_err(failed)?;
                }
                b',' => {
                    if stack.is_empty() {
                        return Err(invalid(line, "a `,` is outside any object or array"));
                    }
                    out.write_all(b",").map_err(failed)?;
                    newline(&mut out, stack.len()).map_err(failed)?;
                }
                b':' => {
                    out.write_all(if indent.is_some() { b": " } else { b":" })
                        .map_err(failed)?;
                }
                _ => {
                    if stack.is_empty() && seen_value && !scalar {
                        // Another value at the top, as in lines of JSON:
                        // on a line of its own, minified or not, so that
                        // two numbers do not run into one.
                        out.write_all(b"\n").map_err(failed)?;
                    }
                    if opened {
                        newline(&mut out, stack.len()).map_err(failed)?;
                        opened = false;
                    }
                    seen_value = true;
                    match byte {
                        b'{' | b'[' => {
                            stack.push(byte);
                            opened = true;
                        }
                        b'"' => in_string = true,
                        b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'-' | b'+' | b'.' => {
                            in_scalar = true;
                        }
                        _ => return Err(invalid(line, "a character that JSON does not use")),
                    }
                    out.write_all(&[byte]).map_err(failed)?;
                }
            }
        }
        at = to;
        progress(at);
    }
    if in_string {
        return Err(invalid(line, "a string is not closed"));
    }
    if !stack.is_empty() {
        return Err(invalid(line, "an object or array is not closed"));
    }
    if indent.is_some() {
        out.write_all(b"\n").map_err(failed)?;
    }
    out.flush().map_err(failed)
}
