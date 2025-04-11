# Contributing to Gumroad

Thanks for your interest in contributing! This document will help you get started.

## Quick Start

1. Set up the repository

```bash
git clone https://github.com/antiwork/gumroad.git
```

2. Set up your development environment

For detailed instructions on setting up your local development environment, please refer to our [README](README.md).

## Development

1. Create your feature branch

```bash
git checkout -b feature/your-feature
```

2. Start the development environment

```bash
bin/dev
```

3. Run the test suite

```bash
bundle exec rspec spec
```

## Testing Guidelines

- Don't use "should" in test descriptions
- Write descriptive test names that explain the behavior being tested
- Group related tests together
- Keep tests independent and isolated
- For API endpoints, test response status, format, and content
- Use factories for test data instead of creating objects directly

## Pull Request

1. Update documentation if you're changing behavior
2. Add or update tests for your changes
3. Make sure all tests pass
4. Request a review from maintainers
5. After reviews begin, avoid force-pushing to your branch
   - Force-pushing rewrites history and makes review threads hard to follow
   - Don't worry about messy commits - we squash everything when merging to main
6. The PR will be merged once you have the sign-off of at least one other developer

## Style Guide

- Follow the existing code patterns
- Use clear, descriptive variable names

## Writing Bug Reports

A great bug report includes:

- A quick summary and/or background
- Steps to reproduce
  - Be specific!
  - Give sample code if you can
- What you expected would happen
- What actually happens
- Notes (possibly including why you think this might be happening, or stuff you tried that didn't work)

## Writing commit messages

We use the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) specification.

A commit message should be structured as follows:

```bash
type(scope): title

description
```

Where type can be:

- `feat`: new feature or enhancement
- `fix`: bug fixes
- `docs`: documentation-only changes
- `test`: test-only changes
- `refactor`: code improvements without behaviour changes
- `chore`: maintenance/anything else

Example:

```
feat(cli): Add mobile testing support
```

## Help

- Check existing discussions/issues/PRs before creating new ones
- Start a discussion for questions or ideas
- Open an [issue](https://github.com/antiwork/gumroad/issues) for bugs or problems
- Any issue with label `help wanted` is open for contributions - [view open issues](https://github.com/antiwork/gumroad/issues?q=state%3Aopen%20label%3A%22help%20wanted%22)

## License

By contributing, you agree that your contributions will be licensed under the [Gumroad Community License](LICENSE.md).
