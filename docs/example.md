# Example document

This document shows what Markdown Editor can do. Open it in the app to see
the editor and the live preview side by side, or read it here: GitHub
renders the same Markdown.

To try it in the app, download this file (on GitHub: *Download raw
file*) and open it with *File > Open*.

## Text

Paragraphs can contain **bold**, *italic*, ***bold italic***,
~~strikethrough~~ and `inline code`. A line that ends with a backslash\
continues on a new line.

> A quote can contain *formatting*
>
> > and other quotes.

---

## Lists

- Bullet points
  - can be nested
    - several levels deep
- and continue afterwards

1. Numbered lists
2. count on their own
   1. and can be nested as well

## Tasks

In the app, a click on a checkbox in the preview checks or unchecks the
task: exactly the character between the brackets changes in the editor,
and ⌘Z undoes it.

- [x] Install Markdown Editor
- [x] Open this document
- [ ] Check this task in the preview
  - [ ] Nested tasks work as well
- [ ] Press ⌘Z to undo

## Tables

| Action | Menu | Shortcut |
| :--- | :---: | ---: |
| Save | File > Save | ⌘S |
| Undo | Edit > Undo | ⌘Z |
| Zoom in | View > Zoom In | ⌘+ |
| Zoom out | View > Zoom Out | ⌘− |
| Actual size | View > Actual Size | ⌘0 |

Columns can be aligned to the left, the center or the right.

## Code

Inline `code` and code blocks keep every character as written:

```rust
fn main() {
    println!("Hello from Markdown Editor");
}
```

```sh
shasum -a 256 -c SHA256SUMS
```

    An indented block is code as well.

## Links

A click on a link in the preview never opens it: the app copies the
address and shows the real host in a short notice. Try it with
[the project on GitHub](https://github.com/droczy/markdown-editor).

Web addresses such as https://example.com and www.example.org become links
by themselves. A click on an email link copies only the address:
[write to someone](mailto:someone@example.com?subject=Hello).

## Things to try in the app

- **Zoom** editor and preview together with *View > Zoom In* (⌘+),
  *Zoom Out* (⌘−) and *Actual Size* (⌘0). The zoom level is kept.
- **Light and dark:** switch the appearance in *System Settings*, and the
  preview follows.
- **Autosave:** every change is saved on its own; earlier versions are
  under *File > Revert To*.
- **Privacy:** *Help > Privacy and Permissions* explains what the app may
  do, and what it never does. It works offline and sends nothing anywhere.

The [feature list](https://github.com/droczy/markdown-editor/blob/main/FEATURES.md)
describes everything in detail, including what is planned.
