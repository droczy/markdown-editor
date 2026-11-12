# Contributing

Thank you for your interest! Please read [SECURITY.md](SECURITY.md) first;
security considerations apply to every change.

## Workflow

- `main` is protected and always releasable. Work happens on short-lived
  branches (`feat/…`, `fix/…`, `sec/…`) and is merged via pull request
  (squash merge) after all CI checks pass and the maintainer approves.
- Every change needs tests. Bugs get a regression test first.
- Update the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md).
- Do not add dependencies without a clear reason stated in the PR.
- All code, comments and documentation are written in English.

## Commit messages and PR titles

[Conventional Commits](https://www.conventionalcommits.org/) are required.
Types: `feat`, `fix`, `sec`, `test`, `docs`, `refactor`, `perf`, `build`,
`ci`, `chore`. Breaking changes use `!` or a `BREAKING CHANGE:` footer.

The body explains the change in detail:

```
feat(core): add task list rendering

Why:
Task lists are part of GitHub Flavored Markdown and commonly used.

What:
- Enable comrak's tasklist extension
- Force rendered checkboxes to be disabled

Security:
Checkboxes are restricted to type="checkbox" and always disabled.

Testing:
- Snapshot test for nested task lists
- Security payload with injected <input> elements
```

## Releases

[Semantic Versioning](https://semver.org/) with tags `vX.Y.Z` and
`vX.Y.Z-beta.N`. Release notes contain an overview, all changes, security
notes, known issues, a test summary and SHA-256 checksums of all artifacts.

## Checks to run locally

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets
cargo test --workspace
cargo deny check
xcrun swift-format lint --strict --recursive apps/macos/App apps/macos/UITests apps/macos/Packages
```

For the macOS app see the build and test commands in the [README](README.md).
