# Stealing from a "frontend CI under 2 minutes" list

Source list: tsc to bun check; oxlint with every rule on; shards filled by recorded test time; PRs run only the
tests the diff can reach; lint, typecheck, build and tests all in parallel.

Two changes shipped on this branch. Neither removes or moves a rule, a test or a job:

1. `vitest.config.ts` loads `@boxicons/react` natively. Whole suite on 4 CPUs: 105s to 66s.
2. The `lint_js` job runs eslint beside vitest. With (1), the job's work on 4 CPUs: 137s to 78s.

Not verified: the effect on a real CI run. Nothing was pushed. Scaling the CI steps (47s + 177s = 224s) by the
4-CPU ratio gives roughly 130s, which would take the Lint JS/TS job from about 4.2 to about 2.6 minutes.

## Where the time goes

Steps of main run 43783151682 (`gh api repos/antiwork/gumroad/actions/runs/43783151682/jobs`):

| Job                | Step                            | Seconds |
| ------------------ | ------------------------------- | ------- |
| Lint JS/TS (252s)  | checkout + node + cache restore | 28      |
|                    | `npm run lint-fast`             | 47      |
|                    | vitest, whole suite             | 177     |
| Typecheck TS (93s) | checkout + ruby + node + cache  | 24      |
|                    | `rails js:export`               | 12      |
|                    | `npm run typecheck`             | 40      |
|                    | test-asset steps (main only)    | 15      |

Vitest is 70% of the slowest frontend job. Neither frontend job is the workflow's critical path: the RSpec shards
take about 7 minutes. Everything here shortens feedback on a JS failure, not the whole workflow.

Why vitest was slow: 183 source files import from the `@boxicons/react` barrel, which re-exports 2,180 icon
modules. The package ships ESM without `"type": "module"`, so vitest cannot hand it to Node and transforms every
icon module itself, again in every isolated test file. `--experimental.importDurations.print` on two test files
showed 5.3s of each file's 5.9s import going to that barrel; resolved to the CommonJS build and loaded by Node it
is 0.45–0.68s.

## Verdicts

| Item                                             | Verdict                                              | Evidence                                                                                                                                                                                                                                                                                                                                                                                           | What changes                                                                                   |
| ------------------------------------------------ | ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| tsc to bun check                                 | rejected here; a real drop-in exists                 | `tsc --noEmit` on TypeScript 6.0.3: 19.6–25.2s locally, 24.4s on 4 Linux CPUs, 40s in CI. `typescript@7.0.2` (the native compiler, `latest` on npm) from a scratch install outside the repo: 5.2–5.5s locally, zero diagnostics on the clean tree, and the same `TS2322` as 6.0.3 on a planted type error.                                                                                         | Nothing in this lane. See "Typecheck".                                                         |
| oxlint, every rule we can turn on                | rejected                                             | With 405 of the 409 configured rule names forced off (only `prettier/prettier`, `import/order`, `import/no-duplicates` and `no-restricted-syntax` left on), eslint took 23.4–24.0s against 28.5s with everything on, same machine, same minute. oxlint 1.93.0 refuses a config that names `no-restricted-syntax`, `import/order`, `react/jsx-no-leaked-render` or a prettier plugin ("not found"). | Nothing. See "Lint".                                                                           |
| shards filled by recorded test time              | already have it for RSpec; rejected for vitest       | RSpec: Knapsack, via `bin/ci-test-relevant-shards`. Vitest has no shards: 299 test files, 3,524 tests, 66–69s on 4 CPUs after change 1. A second runner spends 28s on setup before its first test, to split 66s.                                                                                                                                                                                   | Nothing.                                                                                       |
| PRs run only the tests the diff can reach        | already have it, and better                          | `bin/vitest-ci:3-10`: a static import graph that counts `import type`, follows `import.meta.glob`, and falls back to the whole suite for config changes (`bin/vitest-ci:30-41`). `vitest related` misses type-only edges.                                                                                                                                                                          | Nothing.                                                                                       |
| lint, typecheck, build and tests all in parallel | already have it across jobs; stolen inside `lint_js` | `lint_js`, `typecheck`, `lint_ruby`, `build` and the test shards are separate jobs. Inside `lint_js`, eslint ran before vitest.                                                                                                                                                                                                                                                                    | One step runs both at once. 4 CPUs, with change 1: 31.5s + 66.2s back to back, 78.1s together. |
| (not on the list) vitest import cost             | stolen; the largest win                              | Above.                                                                                                                                                                                                                                                                                                                                                                                             | Change 1.                                                                                      |

## Timings

4 Linux CPUs (Docker `node:22-bookworm`, `--cpuset-cpus=0-3`, tracked files copied in, `npm ci` inside), host
otherwise idle. This is the closest local stand-in for the `ubicloud-standard-4` runner.

| Command                                  | Before | After                                                  |
| ---------------------------------------- | ------ | ------------------------------------------------------ |
| `npm run lint-fast`                      | 31.5s  | 31.5s (unchanged; eslint and its config are untouched) |
| `npx vitest run`                         | 105.2s | 66.2s                                                  |
| `npm run typecheck`                      | 24.4s  | 24.4s (unchanged)                                      |
| the `lint_js` step(s): lint, then vitest | 136.7s | 78.1s (one step, both at once)                         |

Two earlier passes of the same container gave vitest 101.4s to 69.0s and 109.2s to 80.6s, and lint beside vitest
75.9s and 77.7s. A third pass ran while the host was busy and is discarded (190.7s to 158.1s).

macOS, 16 cores, a host that was running other work throughout, so wall-clock is noisy:

| Command                                                    | Before                 | After               |
| ---------------------------------------------------------- | ---------------------- | ------------------- |
| `npm run lint-fast`                                        | 21.0s cold, 20.2s warm | 20.8s, 19.6s        |
| `npm run typecheck`                                        | 25.2s cold, 19.6s warm | 21.0s, 20.6s        |
| `npx vitest run`, default workers, three alternating pairs | 102.8s, 83.7s, 91.7s   | 74.7s, 78.7s, 76.8s |
| `npx vitest run --maxWorkers=4`, three alternating pairs   | 109.4s, 98.9s, 111.5s  | 84.2s, 73.1s, 66.2s |

The very first baseline `npx vitest run` took 38.6s on a quieter machine and the second took 105.6s; no "after"
run was taken under conditions as quiet as that first one, so the alternating pairs are the comparison to trust.
CPU time is steadier than wall-clock: user time fell from about 450s to about 345s, and system time rose from
about 103s to about 153s (Node now reads the 2,180 CommonJS files itself).

Nothing got slower in any paired measurement.

## Parity

No rule moved, so there is no oxlint parity matrix: `eslint.config.js` and `npm run lint-fast` are unchanged, and
all 3,524 tests still run and pass. What changed is how the step reports, so that is what was mutation-tested.
Each case ran the step's script as extracted from the YAML, under `bash --noprofile --norc -eo pipefail`:

| Case                                                                                                                                 | Step exit | Reported                                                                                                                                                                                     |
| ------------------------------------------------------------------------------------------------------------------------------------ | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Clean tree, main-style run                                                                                                           | 0         | `Tests 3524 passed`, `eslint (npm run lint-fast) exited 0`                                                                                                                                   |
| Scratch file breaking four rule classes, branch-push run                                                                             | 1         | `import/order`, `no-console`, `no-restricted-syntax` (the `Routes[...]` message), `@typescript-eslint/consistent-type-assertions`, plus `prefer-template`; `::error::eslint failed (exit 1)` |
| Failing scratch test, lint clean, fork-PR-style run                                                                                  | 1         | `Test Files 1 failed \| 299 passed (300)`, `::error::vitest failed (exit 1)`                                                                                                                 |
| Failing test, and the existing `eslint-disable-next-line no-console` at `app/javascript/utils/inertia_partial_reload.ts:169` removed | 1         | `169:3 error Unexpected console statement no-console`, the failing test, and both `::error::` lines                                                                                          |

One behaviour differs, in the stricter direction: a lint failure used to skip vitest; now both always run.

Fork-PR handling is unchanged: same job condition, same checkout, same cache restore and main-only cache save.
The step's script is inline because a fork PR runs main's workflow against its own checkout, which may predate
any script file the step would call.

Self-tests, all passing: `ruby spec/bin/vitest_ci_test.rb` (38 checks), `ci_gate_scope_test.rb` (13),
`branch_specs_test.rb` (191), `classify_main_spec_failure_test.rb` (82).

## Typecheck

"bun check" cannot be adopted here without adopting bun, and no typechecker was evaluated under that name. The
honest equivalent is the native TypeScript compiler, now the stable `typescript@7`.

It is not shipped here because `typescript` is also the parser behind `typescript-eslint` 8.8.0, which predates
TypeScript 7. Gating on 7 while eslint and editors stay on 6 means two compilers that can disagree; moving
everything to 7 is a toolchain upgrade with its own review. The prize is about 30 of the Typecheck job's 93
seconds, on a job that finishes five minutes before the workflow does.

Not verified: that `typescript-eslint` works on TypeScript 7 at any version.

## Lint

eslint's time is parsing every file and running prettier over it (`TIMING=25`: `prettier/prettier` is 67% of rule
time). The rule classes oxlint can run natively are the cheap ones, so moving them saves at most 4–5s of 28s
locally while adding a second linter, a second config and a parity burden. The four rules that must stay in
eslint keep its whole parse cost.

eslint's own multi-threading (`--concurrency`, 9.34 and later) was also tried: eslint 9.39.5 crashes against
`typescript-eslint` 8.8.0 (`Error while loading rule '@typescript-eslint/no-unused-expressions'`). It needs the
same toolchain upgrade as TypeScript 7 and would mostly help branch pushes, where eslint's 47s is now the whole
step.

## Also tried and rejected for vitest

- `--no-isolate`: 283 tests fail (module state shared between files).
- `--pool=threads`: slower, 89s against 68s at 4 workers.
- `deps.optimizer` for `@boxicons/react`: one file's import drops to 0.5s, but enabling the optimizer breaks
  `vi.importActual` on other packages in 4 test files (`Cannot find module '…index.esm.js&v=…'`).
- Marking the package external without the CommonJS alias: works through Node's module-syntax detection, but
  slower (0.8–0.9s a file) and dependent on that detection.
- A single-file bundle of the icons: 150ms against 260ms a load, about 17 CPU-seconds over the suite, for a build
  step.
