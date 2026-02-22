# Contributing

This project uses Conventional Commits to drive automatic version tags (`vX.Y.Z`).

## Commit Format

Scope is optional.

```text
type: short summary
type(scope): short summary
```

Examples:

- `feat: add workspace symbol mode`
- `fix: handle deleted files in preview`
- `chore(ci): update action versions`

## Version Bump Rules

- `minor`: at least one `feat` commit since last tag.
- `patch`: default (`fix`, `chore`, `docs`, `refactor`, etc).
- `major`: any breaking change.

Breaking changes are marked with either:

```text
feat!: remove deprecated setup option
fix(api)!: rename open() to show()
```
