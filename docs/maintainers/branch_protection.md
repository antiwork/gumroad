# Branch protection guidance

We recommend marking the following checks as required on the main branch once they settle:

- Secret Scan (required)
- Tests (existing)
- CodeQL (optional at first; consider enabling once the noise level is understood)

To do this:

- Settings → Branches → Branch protection rules → Edit main
- Add required status checks by name (exactly as they appear in PR checks)
- Enable “Require pull request reviews” with code owners for .github/workflows and scripts/security
- Optionally require conversation resolution
