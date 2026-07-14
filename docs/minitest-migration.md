# Migrating specs to Minitest + fixtures

The test suite is moving from RSpec + FactoryBot to Minitest + Rails YAML
fixtures. Profiling ([#5801](https://github.com/antiwork/gumroad/issues/5801))
showed 58–77% of wall time in models/controllers/mailers/jobs specs is spent
inside `factory.create`; fixtures load once per process and make each test's
setup cost near zero.

This document is the playbook for moving a spec file over. It's written so a
migration PR can be produced and reviewed mechanically — same file mapping,
same fixture conventions, same verification steps every time.

## Layout

| Piece | Location |
|---|---|
| Tests | `test/**/*_test.rb`, same relative path as the old `spec/**/*_spec.rb` |
| Fixtures | `test/fixtures/<table_name>.yml` (flat, top-level only — Rails won't auto-load subdirectories) |
| Shared helpers/assertions | `test/support/*.rb` (auto-required by `test_helper.rb`) |
| Boot | `test/test_helper.rb` |

CI runs the whole `test/` tree as the `test_minitest` job in
`.github/workflows/tests.yml` (bare runner, no Docker image — services boot as
native GitHub Actions services). The job is wired into the Buildkite
deployment gate alongside `test_fast`/`test_slow`.

## Rules

1. **No FactoryBot in `test/`.** Every `create(:thing)` becomes a fixture row
   or explicit `Model.create!` in `setup` when the object is genuinely
   per-test.
2. **One `*_spec.rb` → one `*_test.rb`**, and the migration PR deletes the
   spec file it replaces. A spec and its test must never both run.
3. **Descriptive fixture names** (`named_seller`,
   `accountant_for_named_seller`), never `one`/`two`.
4. **Migrate in profiling-rank order**: models → mailers →
   policies/presenters/lib/modules → controllers → jobs/sidekiq. Requests and
   services specs are wait-bound, not factory-bound — leave them for the
   system-test track.
5. Keep each PR to one directory slice (or ~20 files max) so review and revert
   stay cheap.

## Fixture gotchas (each of these has burned a real PR)

- **Fixtures bypass validations, callbacks, and `attribute ... default:`.**
  Any column with both a default and a validator must be spelled out on the
  row — for `User` that means at least `user_risk_state` and
  `recommendation_type`, or the first `save!` in a test blows up on a
  validation the test never touched.
- **Renamed foreign keys need `FixtureSet.identify`.** Rails' short form
  (`user: named_seller`) only works when the association name matches the
  model. For `seller_id` pointing at `users`, write
  `seller_id: <%= ActiveRecord::FixtureSet.identify(:named_seller) %>`.
  The `(User)` polymorphic syntax silently writes nothing for non-polymorphic
  columns.
- **`before(:create)` factory hooks become explicit rows.** Example: every
  seller needs an owner-role self-`team_membership` (the
  `owner_membership_must_exist` validation) — see
  `test/fixtures/team_memberships.yml`.
- **RSpec's `stub_const` doesn't exist.** Use `with_const(:NAME, value) { }`
  from `test/support/constant_stubbing_helpers.rb`.
- **`Minitest::Mock#expect` with kwargs** needs the empty positional array:
  `mock.expect(:exists?, true, [], index: "link-test")`.
- **Mailer tests that build `*_url`s in assertions** need
  `include Rails.application.routes.url_helpers` plus a `default_url_options`
  returning `{ host: DOMAIN, protocol: PROTOCOL }`.

## Recipe for one file

1. Read the spec. List every `create(...)`/`let(...)` object and decide:
   shared shape → fixture row (reuse an existing one when possible);
   test-specific mutation → build/mutate inside the test.
2. Add fixture rows. Grep the model for `attribute ... default:` +
   `validates ... inclusion:` pairs and spell those columns out.
3. Write `test/<path>/<name>_test.rb`. `describe/it` → `test "..."`;
   `expect(x).to eq(y)` → `assert_equal y, x`; RSpec
   `permissions :a, :b do ... end` for policies →
   `assert_policy_permits`/`refute_policy_permits` from
   `test/support/policy_assertions.rb`.
4. Run it: `RAILS_ENV=test bin/rails test test/<path>/<name>_test.rb`.
   (Run the whole `test/` tree too — fixture changes can leak into sibling
   tests.)
5. `git rm` the spec file. Run rubocop on the new files.
6. In the PR body: which files moved, spec-vs-test example counts (they should
   match or the body explains why), and local `rails test` output.

## Verification gate for autonomous merges

A migration PR is mergeable when all of:

- Diff touches only `test/**`, `test/fixtures/**`, and deletes the
  corresponding `spec/**` files (no app code).
- Example count in the new tests ≥ example count in the deleted specs, or the
  delta is itemized in the PR body (e.g. a spec that tested RSpec-loader-only
  infrastructure is a documented skip, not a silent drop).
- `test_minitest` and the full existing suite are green.

## What NOT to migrate (document as skips instead)

- Specs testing classes defined under `spec/support/` (RSpec-loader
  infrastructure) — out of scope unless the class is relocated.
- Capybara feature/system specs — those move to the Playwright system-test
  suite (`test/system/`, separate track), not to plain Minitest.
- VCR-heavy external-API specs — keep in RSpec until the cassette strategy
  for Minitest is decided.
