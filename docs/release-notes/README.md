# Release notes

Every release has a file `v<version>.md` here (for example
`v0.1.0-beta.1.md`). The release workflow turns it into the text of the
GitHub release: it replaces the line `<!-- changes -->` with the release's
section of [CHANGELOG.md](../../CHANGELOG.md) (all changes, including
*Security*) and the line `<!-- checksums -->` with the SHA-256 checksums
and how to verify the files. Both lines and the heading `## Known issues`
must appear exactly once.

Template:

```markdown
## Overview

What this release is about, in a few sentences.

<!-- changes -->

## Known issues

What does not work yet or behaves unexpectedly, with workarounds.

## Testing

What was tested for this release: CI results, the full security review,
manual tests.

<!-- checksums -->
```
