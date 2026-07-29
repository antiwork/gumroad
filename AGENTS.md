@CONTRIBUTING.md

## Agent Skills

Project skills live in `.agents/skills/<name>/SKILL.md`. The `.claude/skills/<name>` entries are symlinks for Claude Code compatibility. When adding or updating a project skill, edit `.agents/skills` and keep the matching Claude symlink in place.

## Code comments

Write comments for a reader who already knows this codebase. They are a colleague, not a
student — so say the one thing the code cannot say, and stop.

Keep: the non-obvious *why*, ordering constraints, and traps that will bite the next person
to edit this. Cut: vendor or company history, anything restating the line below it, narration
of how the bug was found, and re-explanations of a named constant the reader can click
through to. If a comment runs past about three lines, ask what you would delete.

A good test: would a maintainer who knows this file find this line worth reading? If not, it
is noise — and noise is what teaches people to skip the comments that matter.
