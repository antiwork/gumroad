#!/usr/bin/env python3
"""Mutation test the migration-wait guards.

Every guard in this change is invisible to outcome-only assertions, so a green suite
is not evidence on its own. This breaks each guard in turn and requires the suite to
go red. MUTANTS_ESCAPED must be 0.

Run: python3 test/db_migrate_wait_mutation_test.py
"""

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Mutations are applied to a THROWAWAY COPY of the repository, never to the working
# tree. Restoring from a backup file is not enough on its own: if the run is killed
# (a hung mutant plus an impatient operator) the backup never gets moved back and a
# broken guard is left committed-ready in the real tree. That happened once.
SOURCE_ROOT = Path(__file__).resolve().parent.parent
ROOT = Path(tempfile.mkdtemp(prefix="db-migrate-mutation-")) / "repo"
shutil.copytree(SOURCE_ROOT, ROOT, ignore=shutil.ignore_patterns(".git"))

COMMON = ROOT / "nomad" / "common.sh"
FAST_PATH = ROOT / "nomad" / "migration_fast_path.sh"
SUITE = ROOT / "test" / "db_migrate_wait_test.sh"

# (name, file, needle, replacement, what escaping it would mean)
MUTANTS = [
    (
        "failure-detection-removed",
        COMMON,
        'if [[ "$active" -eq 0 && "$settled" -gt 0 ]]; then',
        'if false; then',
        "a failed migration hangs the deploy forever again -- the original bug",
    ),
    (
        "settled-guard-dropped",
        COMMON,
        '[[ "$active" -eq 0 && "$settled" -gt 0 ]]',
        '[[ "$active" -eq 0 ]]',
        "the window before Nomad creates allocations is reported as a failed migration",
    ),
    (
        "unreadable-nomad-reads-as-finished",
        COMMON,
        """  if ! rows=$(migration_job_alloc_rows); then
    printf '%s\\t%s\\n' -1 -1
    return 0
  fi""",
        """  rows=$(migration_job_alloc_rows) || rows='cccc3333\tcomplete'""",
        "an unreachable Nomad aborts a healthy deploy",
    ),
    (
        "unparseable-status-reads-as-finished",
        COMMON,
        """  # No Allocations section at all is output we do not recognise, not an empty one.
  if [[ "$status_output" != *"Allocations"* ]]; then
    return 1
  fi""",
        "  :",
        "status output we cannot parse aborts a healthy deploy",
    ),
    (
        "prior-allocations-not-excluded",
        COMMON,
        """    if [[ $'\\n'"${MIGRATION_PRE_EXISTING_ALLOCS}"$'\\n' == *$'\\n'"$id"$'\\n'* ]]; then
      continue
    fi""",
        "    :",
        "a terminal allocation retained from an EARLIER deploy aborts this one before its migration starts",
    ),
    (
        "unknown-baseline-not-fail-safe",
        COMMON,
        """  if [[ "${MIGRATION_ALLOC_BASELINE_KNOWN:-0}" != "1" ]]; then
    printf '%s\\t%s\\n' -1 -1
    return 0
  fi""",
        "  :",
        "a baseline we could not read is treated as 'no prior allocations', so retained ones abort a healthy deploy",
    ),
    (
        "baseline-taken-after-submission",
        FAST_PATH,
        """  snapshot_migration_allocs

  run_job database_migration""",
        """  run_job database_migration

  snapshot_migration_allocs""",
        "this deploy's own allocation lands in the baseline and is excluded from its own failure detection -- the original hanging bug",
    ),
    (
        "job-not-registered-disables-detection",
        COMMON,
        """    if [[ "$status_output" == *"No job(s) with prefix or id"* ]]; then
      return 0
    fi""",
        "    :",
        "the first deploy to register the job, and every fresh cluster, silently loses failure detection",
    ),
    (
        "settle-race-recheck-removed",
        COMMON,
        """      if db_migrate_version_published; then
        logger "db:migrate has completed successfully, proceeding with deployment."
        return 0
      fi

      logger "db:migrate FAILED""",
        """      logger "db:migrate FAILED""",
        "a migration that publishes as its allocation settles is called a failure",
    ),
    (
        "timeout-ceiling-removed",
        COMMON,
        "if (( elapsed >= timeout )); then",
        "if false; then",
        "a job stuck pending forever still hangs the deploy",
    ),
    (
        "alloc-id-match-uses-interval-expression",
        COMMON,
        "$1 ~ /^[0-9a-f-]+$/ && (length($1) == 8 || length($1) == 36) {",
        "$1 ~ /^[0-9a-f]{8}(-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$/ {",
        "the id match silently stops matching on any awk without interval expressions, so every allocation row disappears and failure detection turns itself off",
    ),
    (
        "gr-deploy-ignores-migration-failure",
        COMMON,
        "if ! deploy_database_migrations; then",
        "if deploy_database_migrations && false; then",
        "application code deploys on top of a migration that never ran",
    ),
    (
        "fast-path-swallows-failure",
        FAST_PATH,
        """  if ! wait_for_db_migrate; then
    return 1
  fi""",
        "  wait_for_db_migrate || true",
        "the failure never reaches gr_deploy, and the revision is recorded as migrated",
    ),
]


def run_suite():
    # A mutant that removes a loop's exit condition makes the suite hang rather than
    # fail, so every run is bounded. A timeout counts as red: the guard's absence is
    # exactly what an unbounded loop looks like.
    try:
        return subprocess.run(
            ["bash", str(SUITE)], cwd=ROOT, capture_output=True, text=True, timeout=60
        )
    except subprocess.TimeoutExpired as expired:
        stdout = expired.stdout or b""
        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        return subprocess.CompletedProcess(
            expired.cmd, 124, stdout + "\nFAIL suite did not terminate\n", ""
        )


def red_assertions(stdout):
    # The suite colourises "FAIL", so counting `^FAIL` matches nothing. The trailing
    # summary line is the reliable source; a hung run has no summary at all.
    match = re.search(r"FAILED=(\d+)\s*$", stdout.strip())
    return match.group(1) if match else "suite did not terminate"


def main():
    baseline = run_suite()
    if baseline.returncode != 0:
        print("BASELINE IS RED -- fix the suite before mutation testing")
        print(baseline.stdout[-4000:])
        return 1
    print(f"baseline: {baseline.stdout.strip().splitlines()[-1]}\n")

    escaped = []
    for name, path, needle, replacement, consequence in MUTANTS:
        original = path.read_text()
        if needle not in original:
            print(f"SKIP (mutation did not apply) {name} -- the code no longer matches")
            escaped.append(name)
            continue

        backup = path.with_suffix(path.suffix + ".mutation-backup")
        shutil.copy(path, backup)
        try:
            path.write_text(original.replace(needle, replacement, 1))
            result = run_suite()
            if result.returncode == 0:
                print(f"ESCAPED {name}: suite still green -- {consequence}")
                escaped.append(name)
            else:
                print(f"caught  {name}: red ({red_assertions(result.stdout)} failed assertion(s))")
        finally:
            shutil.move(backup, path)

    after = run_suite()
    if after.returncode != 0:
        print("\nTREE NOT RESTORED -- suite is red after mutation testing")
        return 1

    print(f"\nMUTANTS={len(MUTANTS)} CAUGHT={len(MUTANTS) - len(escaped)} MUTANTS_ESCAPED={len(escaped)}")
    return 1 if escaped else 0


if __name__ == "__main__":
    sys.exit(main())
