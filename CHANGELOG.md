# Changelog

What changed in each release of reqorb, newest first. Add a line under **Unreleased**
with every change a user would notice; [Releasing](docs/releasing.md) moves them under
the new version when it is tagged.

## Unreleased

- In a JSON tree, a value can be shown in the text: tap a value, or the button at
  the end of its row, and the text opens with it selected.
- On iPad, dragging on after a long press selects as the finger goes.
- On an iPad with 3 GB of memory or less, such as an iPad Air 2, responses go to a
  file from 8 MB rather than 16. Formatting JSON, or indenting a large response,
  first checks there is room for it, and a full disk is said plainly.

- Colours in the large-file viewer stay right where a string or a comment runs from
  one screenful into the next, and through a long line split over rows: a 44 MB
  line of JSON is coloured as it reads at any point along it.

- **Open file…**, in the sidebar, the `⌘K` box and `⌘O`, opens a file of any size to
  read and edit: a gigabyte opens at once. Typing works with accents and Chinese or
  Japanese input, with undo, cut, copy and paste, indenting, and find and replace.
  Saving keeps the file's other changes in mind: one made by another program is read
  again, or, if there are edits, saving over it is asked about first. On iPad, where a
  picked file is a copy, it is exported instead.
- A response over 16 MB is written to a file as it arrives, rather than held in
  memory, and shown from there, however large. Copy, save, tests and captures still
  see all of it, up to 256 MB, and **Open to edit** opens it in a page of its own.
- JSON of any size can be explored as a **Tree**, opened a level at a time, in a
  response or a file. A large JSON response is indented for **Pretty** without being
  parsed whole, and **Open file…** can format or minify a JSON file however big.
- Binary responses and files can be shown as bytes, in hexadecimal.
- Any code field, such as a request body, stays quick past a megabyte: pasting in a
  20 MB body no longer stalls the app, and it can still be edited, with brackets
  matched and closed as they are typed. A raw body over 16 MB offers to be sent from a
  file instead, and API specs over a megabyte can now be edited too.
- On iPad, the large-file editor selects a word with a long press or a double tap,
  with handles to drag either end, and a menu to cut, copy, paste or select all; a
  right click brings the same menu up on the Mac. Screen readers hear each line by
  its number, and the line the caret moves to.

## 0.2.0 – 2026-10-17

- Responses and API specs over a megabyte open at once, however large, in a new viewer
  that colours, numbers, selects, copies and searches them. Search can match case, whole
  words or a regular expression, and reaches the end of a 20 MB response in a moment.

## 0.1.0 – 2026-10-17

The first release: the request engine, the `reqorb` command, and the app for macOS and
iPad. The [README](README.md#features) lists what they do.
