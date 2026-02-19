# PR Review Guidance

Supplementary review guidance beyond what CONTRIBUTING.md already covers. Read CONTRIBUTING.md first — this file adds the reviewer's lens.

## Code Clarity Pass (inspired by code-simplifier philosophy)

Evaluate readability and maintainability of new/modified code. The goal is clear, explicit code — not clever or compact code.

Flag:

- Unnecessary nesting that could be flattened (early returns, guard clauses)
- Redundant code that could be consolidated without premature abstraction
- Unclear variable/method names that require mental decoding
- Nested ternaries — prefer if/else or case/switch for multiple conditions
- Overly dense one-liners that sacrifice readability for brevity

Do NOT flag:

- Code that's already clear enough — don't suggest changes for marginal improvement
- Three similar lines that could theoretically be abstracted — duplication is fine if the cases are independent
- Missing type annotations or docstrings on code that's self-explanatory
- Style preferences not backed by CONTRIBUTING.md

## Noise Filtering

Confidence scoring (0–100) for each finding. Only report findings >= 80.

### Always drop (regardless of score)

- Pre-existing issues not introduced by the PR
- Issues a linter, formatter, or type checker would catch
- Style nitpicks not covered by CONTRIBUTING.md
- Changes to lines outside the PR diff
- Suggestions that would add unnecessary complexity or abstraction
- Speculation about potential future bugs without concrete evidence

### Severity levels

- **critical**: Would cause incorrect behavior, data loss, security vulnerability, or production breakage
- **important**: Violates CONTRIBUTING.md, introduces tech debt, or has a meaningful quality impact
- **suggestion**: Could improve clarity or maintainability but isn't wrong as-is
