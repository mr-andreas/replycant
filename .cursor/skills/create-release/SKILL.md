---
name: create-release
description: Create a local release commit from main using a semver argument. It finalizes CHANGELOG.md, commits only changelog entries for that version, creates a v-prefixed tag, and never pushes.
disable-model-invocation: true
---

# Create Release Commit

Use this skill when asked to create a release commit from `main`.

## Inputs

- Required argument: bare semver version like `0.1.3`
- Tag format: `v<version>` (for example `v0.1.3`)

## Required safety checks

Stop immediately if any check fails.

1. Ensure branch is `main`:
   - `git branch --show-current`
2. Ensure working tree is clean:
   - `git status --short`
3. Validate version format:
   - Must match `^\d+\.\d+\.\d+$`
4. Ensure tag does not already exist:
   - `git rev-parse -q --verify "refs/tags/v<version>"`
5. Ensure `CHANGELOG.md` has `## Unreleased` and at least one bullet entry under:
   - `### Breaking changes`
   - `### Features`
   - `### Fixes`

If `## Unreleased` contains no bullet entries, stop and report there is nothing
to release.

## Release workflow

1. Finalize `CHANGELOG.md`.
2. Commit only `CHANGELOG.md` with the release notes copied from that new
   version section.
3. Create tag `v<version>` on that commit.
4. Stop. Never push.

## Update CHANGELOG.md

Transform `CHANGELOG.md` as follows:

1. Replace `## Unreleased` with `## <version> - <YYYY-MM-DD>`.
2. Do not add a new `## Unreleased` section in this release commit.

Use today's date in `YYYY-MM-DD` format.

## Commit message format

Build the commit message from the finalized release section you just created in
`CHANGELOG.md`.

- Subject line:
  - `Release <version>`
- Body:
  - Include category headings and bullet entries copied from that version
    section
  - Omit categories that have no bullet entries
- Do not add a `Co-authored-by` trailer

Use a HEREDOC for commit message formatting.

## Git commands

Run in this order:

1. Stage changelog only:
   - `git add CHANGELOG.md`
2. Commit with HEREDOC message:
   - `git commit -m "$(cat <<'EOF'
Release <version>

### Breaking changes
- ...

### Features
- ...

### Fixes
- ...
EOF
)"`
3. Create lightweight tag:
   - `git tag v<version>`

## Absolute restrictions

- Never run `git push`
- Never run `git push --tags`
- Never run any command that updates remote refs

## Final output to user

Report:

- Commit SHA
- Tag name (`v<version>`)
- Confirmation that nothing was pushed and manual review/push is required

## Example

For input `0.1.3`:

- Release heading becomes `## 0.1.3 - 2026-08-06` (date changes by day)
- Tag becomes `v0.1.3`
