use std::sync::atomic::AtomicBool;

use super::*;

/// A small, seeded source of randomness, so that every run tries the same
/// edits and a failure can be repeated.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: u64) -> u64 {
        if n == 0 { 0 } else { self.next() % n }
    }
}

/// The lines longer than a row, worked out the plain way.
fn expected_long(bytes: &[u8]) -> Vec<(u64, u64)> {
    bytes
        .split(|&b| b == b'\n')
        .enumerate()
        .filter(|(_, line)| line.len() as u64 > ROW_BYTES)
        .map(|(i, line)| (i as u64, line.len() as u64))
        .collect()
}

/// Checks everything a document tells about its text against the text.
fn check(doc: &Document, model: &[u8]) {
    assert_eq!(doc.len(), model.len() as u64);
    assert_eq!(doc.bytes(0, doc.len()), model);
    let lines: Vec<&[u8]> = model.split(|&b| b == b'\n').collect();
    assert_eq!(doc.line_count(), lines.len() as u64);
    assert_eq!(doc.long, expected_long(model));

    let mut at = 0;
    for (i, line) in lines.iter().enumerate() {
        let i = i as u64;
        assert_eq!(doc.line_start(i), at, "start of line {i}");
        assert_eq!(doc.line_end(i), at + line.len() as u64, "end of line {i}");
        at += line.len() as u64 + 1;
    }

    // The rows of each line, put together, are the line.
    let rows = doc.rows(0, usize::MAX);
    assert_eq!(rows.len() as u64, doc.row_count());
    let mut row = 0usize;
    for (i, line) in lines.iter().enumerate() {
        let shown = line.strip_suffix(b"\r").unwrap_or(line);
        let mut joined = Vec::new();
        assert_eq!(doc.row_of_line(i as u64), row as u64);
        while row < rows.len() && rows[row].line == i as u64 {
            let r = &rows[row];
            assert!(r.end - r.start <= ROW_BYTES + 3);
            joined.extend(doc.bytes(r.start, r.end));
            assert_eq!(doc.line_of_row(row as u64), (i as u64, u64::from(r.part)));
            row += 1;
        }
        assert_eq!(joined, shown, "rows of line {i}");
    }
    assert_eq!(row, rows.len());
}

/// Checks that positions go to rows and columns and back.
fn check_positions(doc: &Document, rng: &mut Rng) {
    for _ in 0..20 {
        let at = rng.below(doc.len() + 1);
        let (row, col) = doc.position_of(at);
        let back = doc.offset_of(row, col);
        // A position inside a character, or between `\r` and `\n`, comes
        // back as the nearest one shown before it.
        assert!(back <= at, "{at} came back as {back}");
        assert_eq!(doc.position_of(back), (row, col));
    }
}

fn random_text(rng: &mut Rng) -> String {
    const PARTS: [&str; 9] = [
        "a",
        "bc",
        "\n",
        "\r\n",
        "é",
        "日本",
        "😀",
        "{\"k\": 1}",
        " ",
    ];
    let mut text = String::new();
    let n = rng.below(6);
    for _ in 0..n {
        text.push_str(PARTS[rng.below(PARTS.len() as u64) as usize]);
    }
    // Now and then something long enough to need several rows.
    if rng.below(12) == 0 {
        text.push_str(&"x".repeat(ROW_BYTES as usize + rng.below(3000) as usize));
    }
    text
}

/// Edits, undoes and redoes at random, checking the document against a
/// plain copy of the text after every step.
fn edit_at_random(mut doc: Document, mut model: Vec<u8>, seed: u64, steps: usize) {
    let mut rng = Rng(seed);
    let mut history: Vec<Vec<u8>> = Vec::new();
    let mut undone: Vec<Vec<u8>> = Vec::new();
    check(&doc, &model);
    for _ in 0..steps {
        match rng.below(10) {
            0 | 1 => {
                if doc.undo().is_some() {
                    undone.push(std::mem::replace(&mut model, history.pop().unwrap()));
                } else {
                    assert!(history.is_empty());
                }
            }
            2 => {
                if doc.redo().is_some() {
                    history.push(std::mem::replace(&mut model, undone.pop().unwrap()));
                } else {
                    assert!(undone.is_empty());
                }
            }
            kind => {
                let len = model.len();
                let start = rng.below(len as u64 + 1) as usize;
                let end = (start + rng.below(40) as usize).min(len);
                // Keep whole characters, as an editor would.
                let s = std::str::from_utf8(&model).unwrap();
                let start = (0..=start).rev().find(|&i| s.is_char_boundary(i)).unwrap();
                let end = (end..=len).find(|&i| s.is_char_boundary(i)).unwrap();
                let text = random_text(&mut rng);
                let before = model.clone();
                let steps = doc.undo.len();
                model.splice(start..end, text.bytes());
                doc.replace(start as u64, end as u64, &text, kind == 3);
                // Typing that carried on from the last edit joined it.
                let changed = before != model;
                if doc.undo.len() > steps {
                    history.push(before);
                }
                if changed {
                    undone.clear();
                }
            }
        }
        check(&doc, &model);
        check_positions(&doc, &mut rng);
    }
    // Undoing everything gets back the text as it began.
    while doc.undo().is_some() {
        model = history.pop().unwrap();
    }
    check(&doc, &model);
    assert!(!doc.is_modified());
}

const START: &str =
    "{\n  \"name\": \"reqorb\",\r\n  \"tags\": [\"a\", \"b\"]\n}\n\nlast line é 日本";

#[test]
fn edits_in_memory_match_a_plain_copy() {
    for seed in 1..=5 {
        edit_at_random(
            Document::from_text(START),
            START.as_bytes().to_vec(),
            seed,
            250,
        );
    }
}

#[test]
fn edits_to_a_file_read_in_small_pages_match_a_plain_copy() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("doc.json");
    let mut text = START.repeat(20);
    text.push_str(&"y".repeat(5000));
    text.push('\n');
    fs::write(&path, &text).unwrap();
    for seed in 1..=3 {
        let mut doc = Document::open_paged(&path, 16).unwrap();
        doc.wait_indexed();
        edit_at_random(doc, text.as_bytes().to_vec(), seed * 7, 200);
    }
}

#[test]
fn an_empty_document_has_one_empty_row() {
    let doc = Document::from_text("");
    assert_eq!(doc.line_count(), 1);
    assert_eq!(doc.row_count(), 1);
    let rows = doc.rows(0, 10);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].text, "");
    assert_eq!(doc.position_of(0), (0, 0));
    assert_eq!(doc.offset_of(5, 5), 0);
}

#[test]
fn a_long_line_is_split_into_rows_between_characters() {
    // Two bytes a character, so every split falls in one unless moved.
    let line = "é".repeat(3000);
    let doc = Document::from_text(&format!("a\n{line}\nb"));
    assert_eq!(doc.line_count(), 3);
    assert_eq!(doc.row_count(), 1 + 3 + 1);
    let rows = doc.rows(0, 10);
    assert_eq!(rows[1].part, 0);
    assert_eq!(rows[3].part, 2);
    assert_eq!(rows[4].text, "b");
    let joined: String = rows[1..4].iter().map(|r| r.text.as_str()).collect();
    assert_eq!(joined, line);
    // Columns count UTF-16 units: one for each é.
    let (row, col) = doc.position_of(2 + 2 * 1500);
    assert_eq!((row, col), (2, (1500 - 1024) as u32));
    assert_eq!(doc.offset_of(row, col), 2 + 2 * 1500);
}

#[test]
fn columns_count_utf16_units() {
    let doc = Document::from_text("a😀b\n\u{ff}");
    // The emoji is two units in Dart and four bytes here.
    assert_eq!(doc.position_of(5), (0, 3));
    assert_eq!(doc.offset_of(0, 3), 5);
    assert_eq!(
        doc.offset_of(0, 2),
        1,
        "inside a pair, it goes back to the start"
    );
    assert_eq!(doc.offset_of(0, 99), 6);

    let doc = Document::from_bytes(b"x\xffy".to_vec());
    assert_eq!(doc.rows(0, 1)[0].text, "x\u{fffd}y");
    assert_eq!(doc.position_of(2), (0, 2));
    assert_eq!(doc.offset_of(0, 2), 2);
}

#[test]
fn crlf_line_ends_are_not_shown() {
    let doc = Document::from_text("one\r\ntwo\r\n");
    let rows = doc.rows(0, 10);
    let texts: Vec<_> = rows.iter().map(|r| r.text.as_str()).collect();
    assert_eq!(texts, ["one", "two", ""]);
    assert_eq!(rows[0].end, 3);
    assert_eq!(doc.position_of(4), (0, 3));
}

#[test]
fn typing_is_undone_a_run_at_a_time() {
    let mut doc = Document::from_text("ab");
    for (i, c) in "cde".chars().enumerate() {
        doc.replace(2 + i as u64, 2 + i as u64, &c.to_string(), true);
    }
    doc.replace(1, 1, "X", true); // somewhere else: a new step
    doc.replace(2, 2, "Y", true);
    assert_eq!(doc.text(0, 99), "aXYbcde");
    assert_eq!(doc.undo(), Some(Change { start: 1, end: 1 }));
    assert_eq!(doc.text(0, 99), "abcde");
    assert_eq!(doc.undo(), Some(Change { start: 2, end: 2 }));
    assert_eq!(doc.text(0, 99), "ab");
    assert_eq!(doc.redo(), Some(Change { start: 2, end: 5 }));
    assert_eq!(doc.text(0, 99), "abcde");
    assert!(doc.undo().is_some() && doc.undo().is_none());
}

#[test]
fn replace_all_is_one_step() {
    let mut doc = Document::from_text("a-b-c\nd-e");
    let found = doc
        .snapshot()
        .search(
            &Query {
                text: "-".into(),
                case_sensitive: true,
                ..Query::default()
            },
            &AtomicBool::new(false),
            |_, _| {},
        )
        .unwrap();
    assert_eq!(found.count, 3);
    doc.replace_all(&found.ranges, "\n");
    assert_eq!(doc.text(0, 99), "a\nb\nc\nd\ne");
    assert_eq!(doc.line_count(), 5);
    doc.undo();
    assert_eq!(doc.text(0, 99), "a-b-c\nd-e");
    assert_eq!(doc.line_count(), 2);
    doc.redo();
    check(&doc, b"a\nb\nc\nd\ne");
}

#[test]
fn replace_all_keeps_long_lines_known() {
    let text = format!("{}\n{}", "a,".repeat(2000), "b,".repeat(10));
    let mut doc = Document::from_text(&text);
    let ranges: Vec<_> = (0..2000).map(|i| (i * 2 + 1, i * 2 + 2)).collect();
    doc.replace_all(&ranges, ",,,");
    check(&doc, text.replace("a,", "a,,,").as_bytes());
    doc.undo();
    check(&doc, text.as_bytes());
}

fn find(doc: &Document, query: Query, chunk: u64) -> Vec<(u64, u64)> {
    search::search_in(&doc.text, &query, &AtomicBool::new(false), |_, _| {}, chunk)
        .unwrap()
        .ranges
}

#[test]
fn search_finds_text_and_patterns() {
    let doc = Document::from_text("Cat cat concat\ncat-food CAT");
    let text = |t: &str| Query {
        text: t.into(),
        case_sensitive: true,
        ..Query::default()
    };
    assert_eq!(
        find(&doc, text("cat"), 1 << 20),
        [(4, 7), (11, 14), (15, 18)]
    );
    let any_case = Query {
        text: "cat".into(),
        ..Query::default()
    };
    assert_eq!(find(&doc, any_case.clone(), 1 << 20).len(), 5);
    let words = Query {
        whole_word: true,
        ..any_case
    };
    assert_eq!(
        find(&doc, words, 1 << 20),
        [(0, 3), (4, 7), (15, 18), (24, 27)]
    );
    let pattern = Query {
        text: r"^cat\S*".into(),
        regex: true,
        case_sensitive: true,
        whole_word: false,
    };
    assert_eq!(find(&doc, pattern, 1 << 20), [(15, 23)]);
    let bad = Query {
        text: "(".into(),
        regex: true,
        ..Query::default()
    };
    assert!(search::search(&doc.text, &bad, &AtomicBool::new(false), |_, _| {}).is_err());
}

#[test]
fn search_finds_matches_across_chunks_once() {
    let text = "ab".repeat(500) + "\nneedle\n" + &"ab".repeat(500);
    let doc = Document::from_text(&text);
    let at = text.find("needle").unwrap() as u64;
    for chunk in [1, 2, 3, 5, 7, 64, 1000, 1 << 20] {
        let needle = Query {
            text: "needle".into(),
            case_sensitive: true,
            ..Query::default()
        };
        assert_eq!(
            find(&doc, needle, chunk),
            [(at, at + 6)],
            "chunks of {chunk}"
        );
        let line_start = Query {
            text: "^n".into(),
            regex: true,
            case_sensitive: true,
            whole_word: false,
        };
        assert_eq!(
            find(&doc, line_start, chunk),
            [(at, at + 1)],
            "chunks of {chunk}"
        );
        let every = Query {
            text: "ab".into(),
            case_sensitive: true,
            ..Query::default()
        };
        assert_eq!(find(&doc, every, chunk).len(), 1000, "chunks of {chunk}");
    }
}

#[test]
fn a_cancelled_search_stops() {
    let doc = Document::from_text(&"x".repeat(10));
    let cancel = AtomicBool::new(true);
    let query = Query {
        text: "x".into(),
        ..Query::default()
    };
    assert!(matches!(
        doc.snapshot().search(&query, &cancel, |_, _| {}),
        Err(Error::Cancelled)
    ));
}

#[test]
fn saves_reopens_and_notices_changes_on_disk() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("notes.txt");
    fs::write(&path, "one\ntwo\n").unwrap();
    let mut doc = Document::open(&path).unwrap();
    doc.wait_indexed();
    assert!(!doc.is_modified());
    doc.replace(4, 7, "TWO", false);
    assert!(doc.is_modified());
    doc.save(None, false).unwrap();
    assert!(!doc.is_modified());
    assert_eq!(fs::read_to_string(&path).unwrap(), "one\nTWO\n");
    // The text is still read from the file as it was opened.
    assert_eq!(doc.text(0, 99), "one\nTWO\n");
    doc.undo();
    assert!(doc.is_modified());
    doc.redo();
    assert!(!doc.is_modified());

    // Something else writes the file: saving over it needs saying so.
    std::thread::sleep(std::time::Duration::from_millis(20));
    fs::write(&path, "changed elsewhere, longer").unwrap();
    assert!(doc.changed_on_disk());
    doc.replace(0, 0, "zero\n", false);
    let err = doc.save(None, false).unwrap_err();
    assert!(
        err.to_string().contains("changed by another program"),
        "{err}"
    );
    doc.save(None, true).unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), "zero\none\nTWO\n");

    let copy = dir.path().join("copy.txt");
    doc.save(Some(&copy), false).unwrap();
    assert_eq!(doc.path(), Some(copy.as_path()));
    let reopened = Document::open(&copy).unwrap();
    assert_eq!(reopened.text(0, 99), "zero\none\nTWO\n");
    assert_eq!(
        fs::read_dir(dir.path()).unwrap().count(),
        2,
        "no temporary file left"
    );
}

/// As in the macOS sandbox, where only the file chosen may be written:
/// nothing can be made beside it, so it is written over, and the original
/// the document reads, kept first, still serves undo and the rest.
#[cfg(unix)]
#[test]
fn saves_over_the_file_where_nothing_may_be_written_beside_it() {
    use std::os::unix::fs::PermissionsExt;

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("notes.txt");
    let original: String = (0..2000).map(|i| format!("line {i}\n")).collect();
    fs::write(&path, &original).unwrap();
    let mut doc = Document::open_paged(&path, 64).unwrap();
    doc.wait_indexed();
    doc.replace(0, 4, "LINE", false);
    let end = doc.len();
    doc.replace(end, end, "the end\n", false);
    let edited = doc.text(0, u64::MAX);

    let locked = fs::Permissions::from_mode(0o555);
    fs::set_permissions(dir.path(), locked).unwrap();
    let saved = doc.save(None, false);
    let saved_again = {
        doc.replace(0, 0, "zero\n", false);
        doc.save(None, false)
    };
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o755)).unwrap();
    saved.unwrap();
    saved_again.unwrap();

    let expected = format!("zero\n{edited}");
    assert_eq!(fs::read_to_string(&path).unwrap(), expected);
    assert_eq!(doc.text(0, u64::MAX), expected);
    assert!(!doc.is_modified());
    assert!(!doc.changed_on_disk());
    // Every step back reads the original as it was, from the copy.
    doc.undo();
    doc.undo();
    doc.undo();
    assert_eq!(doc.text(0, u64::MAX), original);
    assert_eq!(doc.line_count(), 2001);
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
}

#[test]
fn a_document_from_memory_needs_somewhere_to_save() {
    let mut doc = Document::from_text("x");
    assert!(doc.save(None, false).is_err());
}

#[test]
fn opening_a_folder_or_nothing_fails() {
    let dir = tempfile::tempdir().unwrap();
    let Err(err) = Document::open(dir.path()) else {
        panic!("a folder opened")
    };
    assert!(err.to_string().contains("is a folder"), "{err}");
    assert!(Document::open(&dir.path().join("missing")).is_err());
}

#[test]
fn tells_binary_from_text() {
    assert!(Document::from_bytes(vec![0x89, b'P', b'N', b'G', 0, 0]).looks_binary());
    assert!(!Document::from_text("plain").looks_binary());
}

#[test]
fn shows_the_start_of_a_file_while_the_rest_is_indexed() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("big.log");
    let text: String = (0..20_000).map(|i| format!("line {i}\n")).collect();
    fs::write(&path, &text).unwrap();
    let mut doc = Document::open_paged(&path, 64).unwrap();
    // Whatever has been found so far reads correctly.
    let progress = doc.indexing();
    let known = doc.line_count().min(100);
    for row in doc.rows(0, known as usize).iter().take(known as usize - 1) {
        assert_eq!(row.text, format!("line {}", row.line));
    }
    assert!(progress.indexed <= progress.len);
    doc.wait_indexed();
    assert_eq!(
        doc.indexing(),
        Indexing {
            indexed: text.len() as u64,
            len: text.len() as u64,
            done: true
        }
    );
    assert_eq!(doc.line_count(), 20_001);
    assert_eq!(doc.rows(19_999, 5)[0].text, "line 19999");
    check(&doc, text.as_bytes());
}

/// Run with `cargo test --release -p reqorb-core -- --ignored --nocapture`.
#[test]
#[ignore = "writes a gigabyte; run by hand to check the timings"]
fn a_gigabyte_stays_fast() {
    use std::time::Instant;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("big.json");
    {
        let mut file = std::io::BufWriter::new(File::create(&path).unwrap());
        let line =
            b"{\"id\": 123456, \"name\": \"a fairly ordinary record\", \"tags\": [\"x\", \"y\"]}\n";
        let mut written = 0;
        while written < 1 << 30 {
            file.write_all(line).unwrap();
            written += line.len();
        }
        file.write_all(b"the needle at the end").unwrap();
    }
    let started = Instant::now();
    let mut doc = Document::open(&path).unwrap();
    let rows = doc.rows(0, 60);
    println!("open and first screen: {:?}", started.elapsed());
    assert_eq!(rows.len(), 60);

    let started = Instant::now();
    doc.wait_indexed();
    println!("index {} lines: {:?}", doc.line_count(), started.elapsed());

    let started = Instant::now();
    let last = doc.row_count() - 60;
    let rows = doc.rows(last, 60);
    println!("last screen: {:?}", started.elapsed());
    assert_eq!(rows.last().unwrap().text, "the needle at the end");

    let started = Instant::now();
    let middle = doc.line_start(doc.line_count() / 2);
    doc.replace(middle, middle, "typed", true);
    doc.replace(middle + 5, middle + 5, "!", true);
    println!("two keystrokes in the middle: {:?}", started.elapsed());

    let started = Instant::now();
    let query = Query {
        text: "needle".into(),
        case_sensitive: true,
        ..Query::default()
    };
    let found = doc
        .snapshot()
        .search(&query, &AtomicBool::new(false), |_, _| {})
        .unwrap();
    println!("search: {:?}", started.elapsed());
    assert_eq!(found.count, 1);

    let started = Instant::now();
    doc.save(None, false).unwrap();
    println!("save: {:?}", started.elapsed());
}
