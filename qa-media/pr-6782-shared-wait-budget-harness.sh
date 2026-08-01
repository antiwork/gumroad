#!/usr/bin/env bash
# Proves the long-running wait budget is SHARED across confirmation rounds rather than refreshed
# per round. Runs the real deploy_production.sh with sleep and curl stubbed, so a 3-minute poll
# costs nothing and we can count how many polls the script is willing to make in total.
#
# Getting this harness to actually discriminate took three attempts, and the two failures are worth
# recording because both LOOKED like passes:
#
#   1. Blocker 503 from the first poll: the initial wait exhausts the whole budget and the script
#      skips before any confirmation round. The re-wait path never runs.
#   2. Blocker clears on the first poll, then busy forever: a confirmation round IS entered, but the
#      initial wait spent ZERO of the budget, so "fresh 40" and "40 minus nothing" are the same
#      number. Buggy and fixed code both report 40 waits and both pass.
#
# To separate them the initial wait must burn PART of the budget and then clear, so the re-wait's
# entitlement differs. Hence: busy for PREFIX polls, then one 200 to drain the initial wait, then
# busy forever so the confirmation poll re-enters it.
#
#   fixed  -> re-wait may use only (40 - PREFIX); total waits stay at 40
#   buggy  -> re-wait restarts at a full 40;      total waits reach PREFIX + 40
#
# PASS means total long-running waits stay inside ONE 40-attempt budget even though the wait was
# entered twice, and the script still exits 0 on its own designed skip path.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/.buildkite/scripts/deploy_production.sh"
BUDGET=40
PREFIX=10
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

cat > "$workdir/curl" <<'STUB'
#!/usr/bin/env bash
# Payout always clears. The long-running blocker is busy for PREFIX polls, clears on the next one
# (draining the initial wait with part of the budget already spent), then is busy forever.
for arg in "$@"; do
  case "$arg" in
    *"/long"*)
      echo 1 >> "$LONG_TALLY"
      n=$(wc -l < "$LONG_TALLY" | tr -d ' ')
      if [ "$n" -le "$PREFIX" ]; then printf '503'
      elif [ "$n" -eq $((PREFIX + 1)) ]; then printf '200'
      else printf '503'
      fi
      exit 0
      ;;
  esac
done
printf '200'
STUB

cat > "$workdir/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat > "$workdir/docker" <<'STUB'
#!/usr/bin/env bash
echo "FAIL: reached the deploy — the script should have skipped instead" >&2
exit 1
STUB

chmod +x "$workdir"/curl "$workdir"/sleep "$workdir"/docker

LONG_TALLY="$workdir/long_polls"
: > "$LONG_TALLY"
export LONG_TALLY PREFIX

PATH="$workdir:$PATH" \
  PAYOUT_HEALTHCHECK_URL="http://stub/payout" \
  LONG_RUNNING_JOBS_HEALTHCHECK_URL="http://stub/long" \
  ECR_REGISTRY="stub" BUILDKITE_COMMIT="0000000000000000" \
  bash "$SCRIPT" > "$workdir/out.log" 2>&1
rc=$?

waits=$(grep -c "Long-running job in flight" "$workdir/out.log" || true)
rounds=$(grep -c "confirmation round" "$workdir/out.log" || true)

echo "exit code                    : $rc (0 = the designed skip path)"
echo "confirmation rounds entered  : $rounds  (must be >=1 or this harness proves nothing)"
echo "waits before the clear        : $PREFIX  (budget deliberately part-spent)"
echo "long-running 3-min waits used: $waits"
echo "shared budget ceiling        : $BUDGET waits = $((BUDGET * 3)) min"
echo "a per-round budget would give : $((PREFIX + BUDGET)) waits here, and up to 200 = 600 min in a 240-min step"
echo
echo "--- decision lines ---"
grep -E "wait attempts left|skipping deployment|budget exhausted" "$workdir/out.log" || true
echo
if [ "$rounds" -lt 1 ]; then
  echo "RESULT: INCONCLUSIVE — never entered a confirmation round, so the re-wait path was untested."
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  echo "RESULT: FAIL — expected the graceful skip (exit 0), got $rc"
  exit 1
fi
if [ "$waits" -gt "$BUDGET" ]; then
  echo "RESULT: FAIL — $waits waits exceeds the $BUDGET-attempt shared budget."
  echo "        The confirmation round refreshed the budget instead of drawing from it:"
  echo "        $PREFIX spent before the clear, then a full $BUDGET again."
  exit 1
fi
echo "RESULT: PASS — the wait was entered across $rounds confirmation round(s), spent $PREFIX attempts"
echo "        before the clear, and still totalled only $waits of the single $BUDGET-attempt budget."
