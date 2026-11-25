# Focusline

**A reading marker for KOReader that keeps your place, one sentence at a time.**

[![Download Focusline](https://img.shields.io/badge/Download-focusline.koplugin.zip-2ea44f?style=for-the-badge)](https://github.com/MRHRTZ/focusline.koplugin/releases/latest/download/focusline.koplugin.zip)
&nbsp;
[![Latest version](https://img.shields.io/github/v/release/MRHRTZ/focusline.koplugin?style=for-the-badge&label=Version)](https://github.com/MRHRTZ/focusline.koplugin/releases/latest)

Focusline highlights the sentence (or the single word) you are reading right
now. Press your page-turn button and the highlight moves to the next
sentence. When it reaches the bottom of the page, the page turns by itself.

It helps if you lose your line easily, get distracted by the rest of the
page, or simply want to pick a book back up at the exact sentence where you
stopped.

<p align="center">
  <img src="images/demo.gif" alt="The marker moving from sentence to sentence" width="560">
</p>

## Features

- **Marks one sentence or one word at a time**, and follows you through the
  book.
- **Six styles**: Box, Lighten, Underline, Strikethrough, Invert and
  Underline (wavy).
- **Eight soft colors**: Muted Rose, Sage, Soft Apricot, Dusty Blue, Muted
  Gold, Lavender, Powder Cyan and Dusty Pink.
- **A small picture beside the line** if you like: a flower, star, leaf or
  arrow, or a picture of your own.
- **Works with your page-turn buttons**, including Bluetooth page turners.
- **Remembers your place.** Close the book, open it tomorrow, and the marker
  is on the same sentence.
- **Can move on its own** at a speed you set, if you want a steady pace.
- **Tap the marker** to change its color or style, or to write a note on it.
- **Works in day mode and night mode.**

## Screenshots

| The marker on a sentence | Word by word |
| --- | --- |
| <img src="images/marker.png" alt="A sentence marked in a book" width="340"> | <img src="images/word.png" alt="A single word marked" width="340"> |
| **Tap the marker to change it** | **A picture beside the line** |
| <img src="images/popup.png" alt="The popup with the eight colors" width="340"> | <img src="images/edge-image.png" alt="A star beside the marked line" width="340"> |
| **Night mode** | **PDF files** |
| <img src="images/night-mode.png" alt="The marker in night mode" width="340"> | <img src="images/pdf.png" alt="The marker in a PDF file" width="340"> |

The six styles:

<p align="center">
  <img src="images/styles.png" alt="Box, Lighten, Underline, Strikethrough, Invert and Underline (wavy)" width="760">
</p>

## How to install

You need [KOReader](https://koreader.rocks) on your e-reader, phone or
tablet.

1. **Download** the file with the green button at the top of this page. You
   get a file called `focusline.koplugin.zip`.
2. **Unzip it** on your computer. You get a folder called
   `focusline.koplugin`.
3. **Connect your device** to the computer with its USB cable.
4. **Copy the `focusline.koplugin` folder** into KOReader's `plugins` folder
   on the device:

   | Device | Where the `plugins` folder is |
   | --- | --- |
   | Kindle | `koreader/plugins` |
   | Kobo | `.adds/koreader/plugins` |
   | PocketBook | `applications/koreader/plugins` |
   | Android | `koreader/plugins` |

   On Kobo the `.adds` folder is hidden. Turn on "show hidden files" on your
   computer to see it.
5. **Restart KOReader.**

When it is in the right place, the `plugins` folder contains a folder named
`focusline.koplugin`, and inside that you see `main.lua`. If you see another
`focusline.koplugin` folder inside it instead, move the inner one up a level.

To update later, download the new file and replace the old folder the same
way. Your settings are kept.

## How to use

### 1. Turn it on

Open a book and tap the top of the screen to show the menu.

1. Tap the **page icon** (the second icon in the top row).
2. Tap **Focusline reading marker**. It is near the bottom of the list.
3. Tick **Enable for this book**.

| Steps 1 and 2 | Step 3 |
| --- | --- |
| <img src="images/step-1-open-menu.png" alt="The page icon and the Focusline reading marker entry" width="340"> | <img src="images/step-2-enable.png" alt="Enable for this book, ticked" width="340"> |

Close the menu by tapping the book. The first sentence on the page is now
marked. You turn Focusline on once for each book you want it in.

### 2. Move the marker

**With page-turn buttons.** Press *next page* to move the marker forward and
*previous page* to move it back. At the end of the page, the page turns and
the marker carries on at the top of the next one. This also works with a
Bluetooth page turner or a keyboard.

**On a device without buttons.** Give the marker a gesture, such as a tap in
a corner of the screen:

1. Show the menu and tap the **gear icon**.
2. Tap **Taps and gestures**, then **Gesture manager**.
3. Pick a gesture, for example **Tap corner**, then **Bottom right**.
4. Tap **Reader**, then tick **Focusline: move marker forward**.

Do the same with another corner and **Focusline: move marker backward** if
you want to go back as well.

**Hands-free.** Let the marker move by itself. In the Focusline menu, tap
**Auto-advance**, tick **Enable auto-advance**, and set how long it stays on
each sentence. It pauses when you turn a page yourself.

If you turn a page by tapping or swiping the screen, the marker jumps to the
top of the new page.

### 3. Make it yours

Tap the marker itself. A small window opens:

- **Colors**: tap one and the marker changes straight away.
- **Note**: write a note on the marked sentence.
- **Style**: choose one of the six styles.
- **Adjust**: make the marked part a little longer or shorter.
- **More**: remove the marker, or copy, look up or translate the marked text.

Everything else is in the Focusline menu:

| The Focusline menu | Colors |
| --- | --- |
| <img src="images/menu.png" alt="The Focusline menu" width="340"> | <img src="images/color-picker.png" alt="Choosing a color" width="340"> |
| **Styles** | **Picture beside the line** |
| <img src="images/style-picker.png" alt="Choosing a style" width="340"> | <img src="images/edge-image-picker.png" alt="Choosing a picture" width="340"> |

| Menu entry | What it does |
| --- | --- |
| Enable for this book | Turns the marker on or off for the book you are reading. |
| Granularity | Mark a whole sentence or a single word. |
| Style | How the marker is drawn. |
| Edge image (decorative icon) | Shows or hides the small picture beside the marked line. |
| Edge image | Which picture to show. **Import PNG/SVG…** lets you use your own. |
| Color | The color of the marker. |
| Quick-style cycle includes | Which styles the "cycle marker style" gesture goes through. |
| Jump to marker when reopening this book | Opens the book on the page where the marker is. On by default. |
| Auto-advance | Moves the marker by itself, at the speed you set. |
| Keyboard / page-turn button bindings | Lets the page-turn buttons move the marker. On by default. Untick it to make the buttons turn pages again. |
| Notify on auto-advance pause | Shows a short message when auto-advance pauses. |

### Good to know

- The marker is saved inside the book as a normal KOReader highlight. You
  will see it in your bookmark list, and you can delete it there like any
  other highlight.
- There is only one marker in a book. It is removed when you reach the end.
- On a black-and-white screen the colors show as shades of gray. The names
  on the color buttons tell you which is which.

## Which books work

| Works | Does not work |
| --- | --- |
| EPUB, FB2, MOBI, TXT, HTML | Comics and manga (CBZ) |
| PDF and DJVU files that contain real text | Scanned pages that are only pictures |

A quick test for a PDF: if you can select words in it with your finger,
Focusline can mark them. If a book cannot be marked, Focusline tells you so
when you try to turn it on.

Tested with KOReader 2026.07.

## Support

Focusline is free. If it makes your reading nicer, you can buy me a coffee.
Thank you!

[![Support me on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/mrhrtz)
