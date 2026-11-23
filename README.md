<p align="center">
    <img src="icon.png" width="160" alt="Running the Table app icon">
</p>

<h1 align="center">Running the Table</h1>

<p align="center">
    Lightweight macOS table editor for clean HTML tables. WYSIWYG grid on top, live HTML source pane below, Notes-style sidebar of saved tables.
</p>
<p align="center">
    macOS 15.6+. Supports Apple Silicon and Intel. Signed and notarized.
</p>

## Download

[Latest release](https://github.com/thomsirveaux01/running-the-table/releases/latest).

## Features

- WYSIWYG grid ⇄ HTML pane with live two-way sync. 
- WYSIWYG table-editing should be similar to most spreadsheet apps, with the ability to add, remove, and move rows and columns, and copy/paste cells. 
- WYSIWYG mode only supports basic table formatting (th, colspan, rowspan, a few others) but other tags typed manually in HTML mode will persist. 
- HTML mode uses IDE-style colors and row numbering. 
- Save any table as a template. 
- Supports pasting existing HTML code directly into the HTML block.
- Import and export CSV and Markdown files, and import Excel (.xlsx) and OpenDocument (.ods) spreadsheets (each sheet becomes a table, formulas resolved, dates shown as dates). Paste cells from Excel/Sheets/Numbers.
- Defaults to saving in sandboxed Documents folder. Select a custom folder to sync with the cloud service of your choice.

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
  Utils/       HTMLGenerator, HTMLParser, HTMLHighlighter, SpreadsheetImporter, FormulaEvaluator
```
