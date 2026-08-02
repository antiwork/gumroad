#!/bin/bash
# Walkthrough for "Land the stale-transient suppression sweep on main".
# Demonstrates the defect (job absent from main + unscheduled) and the fix.
set -u
cd "$(dirname "$0")/.."
export PATH="$HOME/.rbenv/versions/3.4.3/bin:$PATH"

echo "### 1. The job and its schedule entry on origin/main (before this PR)"
git ls-tree -r origin/main --name-only | grep -c stale_transient_suppression_sweep_job.rb \
  | sed 's/^/  job file on main (count): /'
git show origin/main:config/sidekiq_schedule.yml | grep -c StaleTransientSuppressionSweepJob \
  | sed 's/^/  schedule entry on main (count): /'
echo "  merge commit of #6154 is an ancestor of main? \
$(git merge-base --is-ancestor a808c6327 origin/main && echo yes || echo NO)"
echo "  base branch #6154 merged into: $(gh pr view 6154 --repo antiwork/gumroad --json baseRefName --jq .baseRefName)"
echo "  state of that base branch's PR (#6073): $(gh pr view 6073 --repo antiwork/gumroad --json state --jq .state)"

echo
echo "### 2. Same checks on THIS branch (after)"
echo "  job file present: $([ -f app/sidekiq/stale_transient_suppression_sweep_job.rb ] && echo yes || echo no)"
grep -c StaleTransientSuppressionSweepJob config/sidekiq_schedule.yml \
  | sed 's/^/  schedule entry present (count): /'
ruby -ryaml -e 'c=YAML.load_file("config/sidekiq_schedule.yml")["stale_transient_suppression_sweep"];puts "  cron=#{c["cron"]} class=#{c["class"]} queue=#{c["queue"]}"'

echo
echo "### 3. Classifier is fail-closed (the guardrail that keeps this safe)"
ruby -e '
require "active_support/all"; require "./app/services/transient_email_failure_classifier"
{"421 4.7.0 Try again later"=>:transient,
 "error dialing remote address: dial tcp: i/o timeout"=>:transient,
 "552 mailbox full"=>:transient,
 "550 5.1.1 user unknown"=>:hard,
 "550 5.1.1 user unknown (try again later?)"=>:hard,
 "Recipient address rejected: Domain not found"=>:hard,
 "some novel wording we have never seen"=>:unknown,
 ""=>:unknown}.each do |r,want|
  got = TransientEmailFailureClassifier.new(event_type: nil, reason: r).classify
  printf("  %-5s %-10s %s\n", got==want ? "PASS":"FAIL", got, r.empty? ? "(blank reason)" : r)
end'

echo
echo "### 4. Specs"
bundle exec rspec spec/services/transient_email_failure_classifier_spec.rb \
  spec/sidekiq/stale_transient_suppression_sweep_job_spec.rb 2>&1 | tail -3
echo "  siblings (nothing regressed by the EmailSuppressionManager refactor):"
bundle exec rspec spec/services/email_suppression_manager_spec.rb \
  spec/sidekiq/resend_confirmation_email_job_spec.rb 2>&1 | tail -3 | sed 's/^/  /'
