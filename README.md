# Running the Table

A macOS table editor for producing clean HTML tables for a web CMS: a
WYSIWYG grid on top, a live-syncing HTML source pane below, and a
Notes-style sidebar of saved tables.

## Features

- WYSIWYG grid ⇄ HTML pane, bidirectional live sync
- Bold, italic, and links (`Cmd+B` / `Cmd+I` / `Cmd+K`); `th`/`td` cells; colspan 1–6
- Add/remove rows and columns; Google-Sheets-style drag to resize and reorder (gutter handles)
- Spreadsheet keyboard navigation (Tab/Return/Escape)
- One shared undo stack for typing, formatting, structure, and resizing
- Notes-style autosave: tables live in `~/Documents/Running the Table/` as `.html`, no save panels

## Building

Requires Xcode 27 on macOS.

```
xcodebuild -scheme "Running the Table" -configuration Debug build
```

## Versioning

Marketing version stays below 1.0 until the first release (`MARKETING_VERSION`
in the target's build settings). `CURRENT_PROJECT_VERSION` is the build
number and must be incremented on every commit that ships a build; releases
are tagged `v<marketing version>`.

## Layout

```
Running the Table/
  Models/      Table, TableCell, TableDocument
  ViewModels/  TableViewModel — all app state, undo, autosave
  Views/       grid, cells, HTML pane, toolbar
  Utils/       HTMLGenerator, HTMLParser
APP_SPEC.md    design spec and platform-quirk notes
```
