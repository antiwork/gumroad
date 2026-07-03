@CONTRIBUTING.md

## Agent Skills

Project skills live in `.agents/skills/<name>/SKILL.md`. The `.claude/skills/<name>` entries are symlinks for Claude Code compatibility. When adding or updating a project skill, edit `.agents/skills` and keep the matching Claude symlink in place.

## Code comments

Write comments for a reader who is new to the codebase but familiar with the goal of the project. Avoid jargon-dense shorthand: explain *why* the code does what it does in plain language, spell out non-obvious context (invariants, gotchas, links to the decision), and don't assume the reader knows internal nicknames, prior incidents, or module history. A good test: someone on day one who knows what the product does should understand the comment without grepping elsewhere.
