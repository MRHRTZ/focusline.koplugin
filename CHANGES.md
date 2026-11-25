# Changelog

## 0.2.0

### Looks

- Three new styles: **Border** (like Box, but outline only, no fill),
  **Pinned** (a pale tinted band with a text-selection-style handle, a
  vertical bar and a round dot, at the very start and very end of the
  marked text), and seven ornamental underlines modeled on decorative page
  dividers: diamonds, flourish, leaves, scroll, flower, bow and quill. Each
  draws its ornament either at the true first and last line of a wrapped
  sentence (diamonds, flourish) or centered on every line (leaves, scroll,
  flower, bow, quill). 17 styles in total.
- "Lighten" was removed: its translucent fill looked the same as Box on
  screen. A book that still has an old "Lighten" marker keeps working; it
  is shown as Box instead.
- The style picker and all style previews, including the new ones, invert
  correctly in night mode.

### Moving the marker

- **Auto-advance** now has two modes: **Manual**, where the marker stays on
  each sentence for a fixed interval you set in milliseconds (as before),
  and **Auto**, where the time is worked out from the sentence itself: its
  word count and a reading speed (words per minute) you set, so long
  sentences get more time than short ones.
- **Persistent marker**, on by default: turning pages yourself (button, tap
  or swipe) no longer moves the marker off its sentence. It stays exactly
  where it was; pressing the button that moves the marker forward or
  backward first brings you back to it, then moves it from there on the
  next press. A new **Move marker to this page** action brings the marker
  to the page you are looking at, when you want that. Turn this off to get
  the old behavior back, where the marker jumps to the top of every page
  you turn to.
- The default quick-style cycle list now includes Border and Pinned
  alongside the older entries; existing custom cycle lists are left
  untouched.

## 0.1.0 - first release

### The marker

- One marker that highlights the word or sentence you are reading and moves
  with you. It is a real KOReader highlight: it is saved with the book, shows
  up in the bookmark list, can carry a note, and can be deleted like any
  other highlight. There is only ever one per book, and it is removed when
  you reach the end of the book.
- Word or sentence steps, switchable at any time without losing your place.
- Headings and paragraphs are kept apart: a chapter title is its own step and
  never runs into the first sentence of the text below it.
- Works in EPUB, FB2, MOBI, TXT and HTML books, and in PDF and DJVU files
  that contain real text. Picture-only files (scans without text, comics,
  CBZ) show a short explanation instead.

### Looks

- Six styles: Box, Lighten, Underline, Strikethrough, Invert and Underline
  (wavy).
- Eight colors: Muted Rose, Sage, Soft Apricot, Dusty Blue, Muted Gold,
  Lavender, Powder Cyan and Dusty Pink. Each swatch shows its name.
- An optional small picture beside the marked line: Flower, Star, Leaf or
  Arrow, or your own PNG or SVG file. It is placed in the free space next to
  the line and never covers the text.
- Colors, pictures and previews look the same in night mode as in day mode.

### Moving the marker

- Page-turn buttons (and Bluetooth page turners) move the marker one step;
  the page turns by itself when the marker reaches the end of it. On by
  default.
- Five actions for KOReader's gesture manager: enable/disable, move forward,
  move backward, cycle style and toggle auto-advance.
- Auto-advance: the marker moves on its own every so many milliseconds, and
  pauses when you turn a page yourself.

### Convenience

- Tap the marker for a popup with the colors, plus Note, Style, Adjust (move
  the start or end of the marked text) and More (delete, details, copy,
  dictionary, translate, search).
- The marker is still on the same words, in the same style and color, when
  you close a book and open it again. If the book opens on another page,
  KOReader jumps to the marker. On by default.
- All settings live in one menu: the page icon in the top menu, then
  "Focusline reading marker".
