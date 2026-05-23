# Full CI Migration — Minitest + Playwright (every phase, delete spec/)

You are continuing the migration started in PR #5210 (Bootstrap Minitest, 40 pure-Ruby specs converted) and PR #5240 (test/system Playwright bootstrap, 15 auth tests).

**Branch:** `full-test-migration` on `/tmp/full-migration`. Already includes:
- `test/test_helper.rb` — Minitest base class, file_fixture_path pointing at `spec/support/fixtures`, conditional `fixtures :all`
- `test/system/` — Playwright driver, server, system_test_case base, 5 auth tests (login/signup/2FA/password-reset/smoke)
- `test_minitest` CI job in `.github/workflows/tests.yml` — runs against Docker test image
- Minitest 5.25 pin in Gemfile (avoids Rails 7.1 incompat with 6.x)
- 40 pure-Ruby specs already converted (test/lib/, test/helpers/, test/validators/, test/sidekiq/, test/observers/, test/presenters/, test/models/help_center/)

**Your job: finish it.** Migrate the remaining ~1,476 RSpec files, delete `spec/`, replace the CI workflow, remove RSpec gems.

This is a multi-hour grind. Use `/goal`. Don't stop until the validation gate passes.

Antiwork CONTRIBUTING.md applies. Read it: `cat CONTRIBUTING.md`.

## STUDY EXISTING PATTERNS FIRST

Before writing anything, read these and use them as the template:

1. **`test/test_helper.rb`** — base setup, fixtures config
2. **`test/lib/utilities/credit_card_utility_test.rb`** — simple unit test conversion
3. **`test/sidekiq/handle_stripe_event_worker_test.rb`** — worker test with `Minitest::Mock` for `expect(Klass).to receive(:method)` patterns
4. **`test/lib/discover_domain_constraint_test.rb`** — the `with_const` helper pattern (consider hoisting to `test/support/`)
5. **`test/system/login_test.rb`** + **`test/system/system_test_case.rb`** — Playwright system test pattern

The existing 40 conversions are the ground truth for style. Follow them exactly.

## PHASE A — Unit/integration spec migration (~1,476 remaining files)

Convert every remaining `spec/**/*_spec.rb` to `test/**/*_test.rb`:

| Source | Target | Base class |
|---|---|---|
| `spec/models/*_spec.rb` (344) | `test/models/` | `ActiveSupport::TestCase` |
| `spec/controllers/*_spec.rb` (265) | `test/controllers/` | `ActionController::TestCase` (or merge into integration) |
| `spec/requests/*_spec.rb` (206) | `test/integration/` | `ActionDispatch::IntegrationTest` |
| `spec/services/*_spec.rb` (180) | `test/services/` | `ActiveSupport::TestCase` |
| `spec/sidekiq/*_spec.rb` (177 remaining) | `test/sidekiq/` | `ActiveSupport::TestCase` |
| `spec/policies/*_spec.rb` (60) | `test/policies/` | `ActiveSupport::TestCase` |
| `spec/mailers/*_spec.rb` (23) | `test/mailers/` | `ActionMailer::TestCase` |
| `spec/presenters/*_spec.rb` (91 remaining) | `test/presenters/` | `ActiveSupport::TestCase` |
| `spec/lib/*_spec.rb` (15 remaining) | `test/lib/` | `ActiveSupport::TestCase` |
| `spec/helpers/*_spec.rb` (9 remaining) | `test/helpers/` | `ActionView::TestCase` |
| `spec/modules/*_spec.rb` (52) | `test/modules/` | `ActiveSupport::TestCase` |
| `spec/business/*_spec.rb` (51) | `test/business/` | `ActiveSupport::TestCase` |
| `spec/channels/*_spec.rb` (3) | `test/channels/` | `ActionCable::Channel::TestCase` |
| `spec/observers/*_spec.rb` (0 remaining) | `test/observers/` | `ActiveSupport::TestCase` |
| `spec/validators/*_spec.rb` (0 remaining) | `test/validators/` | `ActiveSupport::TestCase` |
| `spec/routing/*_spec.rb` | `test/routing/` | `ActionDispatch::IntegrationTest` |
| `spec/config/*_spec.rb` | `test/config/` | as appropriate |
| `spec/factory_bot_linting_spec.rb` | `test/factory_bot_linting_test.rb` | `ActiveSupport::TestCase` |

### Conversion rules

(Follow the patterns in the existing 40 conversions.)

- `RSpec.describe X do … it "does Y" do … end` → `class XTest < … ; def test_does_y ; … ; end ; end` — match the existing files' style exactly
- `let(:foo) { … }` → memoized instance method (`def foo; @foo ||= …; end`) or `setup do @foo = … end`
- `before { … }` → `setup do … end`
- `after { … }` → `teardown do … end`
- `expect(x).to eq(y)` → `assert_equal y, x`
- `expect(x).to be_truthy` → `assert x`
- `expect(x).to be_falsey` → `refute x`
- `expect(x).to be_nil` → `assert_nil x`
- `expect(x).to include(y)` → `assert_includes x, y`
- `expect(x).to match(/r/)` → `assert_match /r/, x`
- `expect { … }.to raise_error(Foo)` → `assert_raises(Foo) { … }`
- `expect { … }.to change { X.count }.by(1)` → `assert_difference -> { X.count }, 1 do … end`
- `expect { … }.not_to change { X.count }` → `assert_no_difference -> { X.count } do … end`
- `allow(x).to receive(:y).and_return(z)` → `x.stub(:y, z) do … end` (Minitest stubs are block-scoped; restructure the test to wrap the action)
- `expect(Klass).to receive(:method).with(args)` → `Minitest::Mock.new.expect(:method, return_value, [args]); Klass.stub :method, mock` — see `test/sidekiq/handle_stripe_event_worker_test.rb`
- `subject` → spell out the receiver
- `described_class` → spell out the class name
- `shared_examples` → module mixed into the test class
- `context "when X" do … end` → either a nested test class or method-name prefixes (`test_when_x_does_y`)
- `stub_const("X::Y", v) { … }` → use the `with_const` helper (lift to `test/support/with_const.rb` and require it from `test_helper.rb`)

### Keep what works

- **FactoryBot stays.** `factory_bot_rails` works with Minitest. Move `spec/factories/` → `test/factories/`. Add `include FactoryBot::Syntax::Methods` to `ActiveSupport::TestCase` in `test/test_helper.rb`. Don't convert 233 factories to fixtures.
- **VCR stays.** Move `spec/cassettes/` → `test/cassettes/`. Update `vcr.configure` block.
- **WebMock stays.**
- **Database Cleaner / transactional fixtures:** Rails' default `use_transactional_tests = true`. Where DB cleanup is needed across threads (system tests), preserve the existing pattern.
- **Pundit policy tests:** convert `permissions :action do …; it "allows" do expect(subject).to permit(…); end; end` to direct calls — `assert Klass.new(user, record).action?`. Don't add `pundit-matchers`.

### Shared support files

- `spec/support/**/*.rb` → `test/support/**/*.rb`. Require from `test_helper.rb`: `Dir.glob(Rails.root.join("test", "support", "**", "*.rb")).each { |f| require f }`
- `spec/shared_examples/**/*.rb` → `test/shared_examples/**/*.rb`, converted to modules
- `spec/support/schemas/*` (JsonMatchers schemas) → keep but rename if RSpec-specific. Replace `JsonMatchers.match_response_schema(:foo)` with explicit `JSON::Validator.validate!(schema_path, payload)` using the `json-schema` gem (add to Gemfile if not present).

## PHASE B — System tests

`test/system/` already has the auth tests + Playwright driver. Migrate **all remaining RSpec system specs**.

```bash
# Find all system specs (the 197 number from the RSpec side — find them on this branch):
grep -rlE 'type:\s*:system|js:\s*true' spec/ 2>/dev/null
find spec/system 2>/dev/null
find spec/features 2>/dev/null
```

Convert each one:
- Inherit from `SystemTestCase` (the existing base class at `test/system/system_test_case.rb`)
- Use Playwright directly (no Capybara)
- URL-transition assertions > DB-state assertions
- DHH-style fixtures where reasonable, FactoryBot where state setup is complex

## PHASE C — Delete spec/

Once every `spec/**/*_spec.rb` has a Minitest equivalent and the suite is green:

```bash
git rm -r spec/
```

Remove from Gemfile (test/development groups):
- `rspec`, `rspec-rails`, `rspec-retry`, `rspec-github`, `rspec_junit_formatter`, `rspec-sidekiq`, `rubocop-rspec`, `spring-commands-rspec`
- `knapsack_pro`
- `json_matchers` (replace with `json-schema`)
- `capybara`, `capybara_accessible_selectors`, `puffing-billy` (verify nothing under test/ requires them)
- `webmock` — keep but change `require: "webmock/rspec"` → `require: "webmock/minitest"`

Add (if not present):
- `minitest-reporters`
- `mocha` (only if you need it; Minitest::Mock + stub is usually enough)
- `json-schema`

Remove the duplicate `gem "minitest", "~> 5.25"` line (a second `~> 5.27` pin shows up in the bootstrap; keep one).

## PHASE D — CI workflow

Replace `.github/workflows/tests.yml`. **Current state has 18 fast + 50 slow shards + test_minitest job.** Replace with a unified Minitest pipeline targeting **4-minute wall**:

```yaml
name: Tests
on:
  pull_request:
  push:
    branches: [main]

jobs:
  build:
    # keep the existing Docker image build (CI services need it)
    ...

  test_unit:
    needs: build
    runs-on: ubicloud-standard-4
    steps:
      - uses: actions/checkout@v4
      - run: docker compose -f docker/docker-compose-test-and-ci.yml up -d db_test redis mongo elasticsearch
      - run: bin/rails test test/models test/services test/lib test/helpers test/modules test/presenters test/policies test/mailers test/sidekiq test/jobs test/channels test/observers test/validators test/business test/config
      # parallelize(workers:4) handled inside ActiveSupport::TestCase

  test_integration:
    needs: build
    strategy:
      fail-fast: false
      matrix:
        shard: [1, 2]
    runs-on: ubicloud-standard-4
    steps:
      - uses: actions/checkout@v4
      - run: docker compose -f docker/docker-compose-test-and-ci.yml up -d
      - run: bin/rails test:integration test/integration test/controllers test/requests test/routing -- --shard ${{ matrix.shard }}/2

  test_system:
    needs: build
    strategy:
      fail-fast: false
      matrix:
        shard: [1, 2, 3, 4, 5, 6]
    runs-on: ubicloud-standard-4
    steps:
      - uses: actions/checkout@v4
      - run: docker compose -f docker/docker-compose-test-and-ci.yml up -d
      - run: bin/rails test:system -- --shard ${{ matrix.shard }}/6
```

**Specifics:**
- **No Knapsack.** Static manifest at `test/.shards.yml` mapping file → shard index. Distribute alphabetically initially (Codex can refine later from CI timings).
- **In-process parallelism:** `parallelize(workers: 4)` in `ActiveSupport::TestCase` and `ActionDispatch::IntegrationTest`. System tests are NOT in-process parallel.
- **Setup budget:** <60s. The existing Docker test image continues to be the base.
- **Flaky-spec capture:** the current workflow uploads `flaky-specs-*` artifacts. Adapt for Minitest using `minitest-retry` plugin OR a custom reporter.
- **Screenshots on failure:** `SystemTestCase` already captures Playwright screenshots.
- **Wall target:** 4 minutes. Compute: ~35-40 CI-min/run.

Delete:
- `.github/workflows/system-tests.yml` if it exists
- `.knapsack_pro.yml` if it exists
- The standalone `test_minitest` job (folded into `test_unit`)

Keep:
- `Unblock deployment from Buildkite` gate, wired to the new test_* jobs

## PHASE E — CONTRIBUTING.md + skills

Update `CONTRIBUTING.md`:
- Remove RSpec/Knapsack/Capybara/Selenium references
- Add: "tests live in `test/`; use Minitest"
- Add: "`bin/rails test` runs unit, `bin/rails test:integration` for integration, `bin/rails test:system` for system"
- Update AI-assisted-PR + ≤100 LOC sections only if directly affected

Update `.agents/skills/gumroad-dev-conventions/SKILL.md` (and the `.claude/skills` symlink) if it references RSpec patterns.

## RULES

1. **One commit per directory batch.** ~50-100 specs per commit. Each message: `migrate(<scope>): convert <N> specs from rspec to minitest`. Don't squash into one giant commit.
2. **AI-assisted footer + `Co-Authored-By: Codex <codex@openai.com>`** on every commit.
3. **No force pushes.**
4. **Don't delete `spec/` until the Minitest suite is green.** Run scoped `bin/rails test test/<dir>/` after each batch.
5. **Don't touch `app/` code** unless a test exposes a real bug. Migration is mechanical.
6. **Don't convert factories to fixtures.** Out of scope.
7. **If you hit a spec that's truly broken on `main` (pre-existing flake), skip it with a comment and log it in `MIGRATION_NOTES.md`.** Don't get stuck.
8. **`bundle exec rubocop` on changed files** before each commit.
9. **`ruby -c` on every modified file** before committing.

## VALIDATION GATE (goal complete when ALL pass)

1. `git ls-files spec/ | wc -l` → `0`
2. `bin/rails test` exits 0
3. `bin/rails test:integration` exits 0
4. `bin/rails test:system` exits 0
5. `grep -E 'rspec|knapsack_pro|json_matchers' Gemfile` returns nothing
6. `.github/workflows/tests.yml` matches the unified design above (no Fast/Slow shards, no Knapsack)
7. `git grep -rE 'RSpec\.|^\s*describe |^\s*it [\"\\x27]' --include='*.rb' -- test/` returns no hits
8. `MIGRATION_REPORT.md` exists at `/tmp/full-migration/` with: per-phase commit hashes, before/after spec counts by directory, skipped specs with reasons, CI workflow changes summary, estimated wall-time delta.

## PITFALLS (Codex-specific)

- **Don't run the FULL `bin/rails test` after every commit.** Too slow. Run scoped subsets per directory.
- **VCR cassette path:** check VCR finds cassettes after moving `spec/cassettes/` → `test/cassettes/`.
- **`described_class`/`subject`:** spell them out, don't try to monkey-patch.
- **`shared_examples`/`include_examples`/`it_behaves_like`:** convert to modules under `test/shared_examples/`.
- **Time helpers:** `travel_to`, `freeze_time` work natively in Minitest.
- **Sidekiq inline vs fake:** preserve per-test mode.
- **Worker delegate pattern:** see `test/sidekiq/handle_stripe_event_worker_test.rb` — `Klass.stub(:method, ->(arg) { ... })` + closure variable for "received args" assertions, or `Minitest::Mock` when next-call result matters.
- **`with_const` helper:** lift the duplicated copies from `test/lib/discover_domain_constraint_test.rb` and `test/lib/gumroad_domain_constraint_test.rb` to `test/support/with_const.rb` and require it from `test_helper.rb`. Greptile flagged this.
- **Orphaned blocks:** Codex sometimes leaves an orphaned `rescue` outside a `begin` from a partial patch. ALWAYS `ruby -c` and visually inspect committed Ruby for balanced `def`/`end` and `begin`/`rescue`/`end` chains.
- **Sandbox DB:** parent agent confirmed MySQL/Redis/Mongo/ES are reachable from this worktree. You CAN run `bin/rails db:test:prepare` and `bin/rails test test/<file>_test.rb`.

GO.
