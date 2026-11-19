# Features

What the macOS app can do today (macOS 26 or later, Apple Silicon). The
[example document](docs/example.md) shows the features in one file, the
[changelog](CHANGELOG.md) has the details, the [security policy](SECURITY.md)
the security model.

## Editing

- Plain-text editor in the system font, with soft line wrap and real tab
  characters.
- The editor never changes your text on its own: smart quotes and dashes,
  text replacement, spelling correction, link detection, inline predictions
  and writing tools are off. Pasted text arrives as plain text.
- Undo and redo per typing step.
- Zoom for editor and preview together: *View > Zoom In* (⌘+), *Zoom Out*
  (⌘−) and *Actual Size* (⌘0), kept across launches.
- Stays responsive with very long lines, such as data without line breaks.

## Preview

- Editor on the left, preview on the right, each taking half of the window.
- CommonMark and GitHub Flavored Markdown: tables, task lists,
  strikethrough and autolinks.
- Updates after a short pause in typing and keeps its scroll position.
- Follows the light or dark appearance of the system.
- Task checkboxes can be clicked: the task is checked or unchecked in the
  text, and ⌘Z undoes it.
- Links are never opened. A click copies the address (for email links only
  the address), and a short notice shows the real host.
- Images are shown as placeholders with their description; nothing is
  loaded.
- Documents that are too large or too complex for the preview get a notice;
  the editor keeps working.

## Files

- Opens and saves `.md` and `.markdown` files. Plain-text files can be
  opened with the app (*Open With*) and keep their name and type.
- UTF-8 only, files up to 50 MiB. Other files are refused with a clear
  message and left unchanged.
- Saves like other Mac apps: autosave in place, earlier versions under
  *File > Revert To*. Changes made by other apps are never overwritten
  silently.
- Line endings, a missing final newline and a byte order mark are kept.
- Every document opens in its own window.

## Privacy and security

- Works offline: loads nothing from the internet, sends nothing anywhere,
  collects no usage data.
- Runs in the App Sandbox with access only to the files you open or save.
  *Help > Privacy and Permissions* explains the permissions.
- Documents are treated as untrusted: raw HTML is shown as text, scripts
  never run, and the preview is locked down in several independent ways.
- Security reviews, the threat model and their reports are published in
  [docs/security](docs/security/).

## Planned

In this order:

1. Comfort: syntax highlighting in the editor, search and replace, scroll
   sync between editor and preview, code highlighting in the preview, local
   images and links to headings.
2. Folders: a file tree, and relative links that open other Markdown files.
3. Math (LaTeX).
4. Mermaid diagrams.
5. Version 1.0 for macOS: PDF export, settings, comparing document
   versions and accessibility.
6. The Linux app (GTK 4/libadwaita, Flatpak).
