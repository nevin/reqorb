# Changelog

What changed in each release of reqorb, newest first. Add a line under **Unreleased**
with every change a user would notice; [Releasing](docs/releasing.md) moves them under
the new version when it is tagged.

## Unreleased

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

## 0.2.0 – 2026-10-17

- Responses and API specs over a megabyte open at once, however large, in a new viewer
  that colours, numbers, selects, copies and searches them. Search can match case, whole
  words or a regular expression, and reaches the end of a 20 MB response in a moment.

## 0.1.0 – 2026-10-17

The first release: the request engine, the `reqorb` command, and the app for macOS and
iPad. The [README](README.md#features) lists what they do.
