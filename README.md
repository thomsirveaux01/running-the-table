# Running the Table

Lightweight macOS table editor for clean HTML tables. WYSIWYG grid on top, live HTML source pane below, Notes-style sidebar of saved tables.

## Download

[Latest release](https://github.com/thomsirveaux01/running-the-table/releases/latest). macOS 15.6+. Supports Apple Silicon and Intel. Signed and notarized.

## Features

- WYSIWYG grid ⇄ HTML pane with live two-way sync. 
- WYSIWYG table-editing should be similar to most spreadsheet apps, with the ability to move rows and columns, copy/paste cells
- WYSIWYG mode only supports basic table formatting (th, colspan, rowspan, a few others) but other tags typed manually in HTML mode will persist. 
- Autosaves `.html` to `~/Documents/Running the Table/`, no save panels
- HTML mode uses IDE-style colors, row numbering. 
- Save any table as a template. 
- Supports pasting existing HTML code directly into the HTML block.
- Basic iCloud file syncing so data can sync between multiple Macs. Supports changing the default location of the save folder, for those who want to use something else.

## Building

Requires Xcode 27.

```
xcodebuild -scheme "Running the Table" -configuration Debug build
```

## Layout

```
Running the Table/
  Models/      Table, TableCell, TableDocument
  ViewModels/  TableViewModel — all app state, undo, autosave
  Views/       grid, cells, HTML pane, toolbar
  Utils/       HTMLGenerator, HTMLParser, HTMLHighlighter
```
