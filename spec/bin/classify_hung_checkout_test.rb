#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/classify-hung-checkout.
#
# Plain ruby, no Rails: the classifier only ever sees a GitHub jobs payload, and
# the reason it lives in a file at all is so this test drives the same code the
# workflow runs.
#
#   ruby spec/bin/classify_hung_checkout_test.rb

require "json"
require "open3"
require "time"
require "yaml"

CLASSIFIER = File.expand_path("../../bin/classify-hung-checkout", __dir__)

$failures = []
$count = 0

# Steps arrive as [name, conclusion, seconds]; timestamps are synthesised in
# order because the classifier reads step durations, not wall-clock positions.
def job(name, conclusion, steps)
  clock = Time.utc(2026, 8, 20, 12, 0, 0)
  @next_id = (@next_id || 100) + 1
  built = steps.each_with_index.map do |(step_name, step_conclusion, seconds), index|
    started = clock
    clock += (seconds || 0)
    {
      "name" => step_name,
      "number" => index + 1,
      "status" => "completed",
      "conclusion" => step_conclusion,
      "started_at" => started.iso8601,
      "completed_at" => clock.iso8601
    }
  end
  { "id" => @next_id, "name" => name, "conclusion" => conclusion, "steps" => built }
end

def hang_annotations(job, step_name = "Check out repository")
  { job["id"].to_s => ["The action '#{step_name}' has timed out after 5 minutes"] }
end

def run(payload, *argv)
  stdout, stderr, status = Open3.capture3("ruby", CLASSIFIER, *argv, stdin_data: JSON.dump(payload))
  [status.exitstatus, stdout + stderr]
end

def check(name, payload, expect:)
  $count += 1
  code, output = run(payload)
  # Exact code, not just nonzero: the workflow re-runs on 0 and has to leave the
  # run alone on everything else.
  actual = code.zero? ? :rerun : :skip
  if actual == expect
    puts "  ok    #{name}"
  else
    puts "  FAIL  #{name}"
    $failures << "#{name}\n    expected #{expect}, got #{actual} (exit #{code})\n    #{output.strip}"
  end
end

puts "classify-hung-checkout"

HUNG_CHECKOUT = [["Set up job", "success", 3], ["Check out repository", "failure", 300], ["Run tests", "skipped", 0]].freeze
HUNG_TRUSTED = [["Set up job", "success", 3], ["Check out repository", "success", 11], ["Check out trusted workflow files", "failure", 300], ["Run tests", "skipped", 0]].freeze
SPEC_FAILURE = [["Check out repository", "success", 10], ["Run tests", "failure", 700]].freeze

hang = job("Slow 3", "failure", HUNG_CHECKOUT)
check(
  "a 300s checkout timeout with tests never started",
  { "jobs" => [hang], "annotations" => hang_annotations(hang), "conclusion" => "failure" },
  expect: :rerun
)

# Relevant shards can hang on either checkout; both carry the same timeout.
trusted = job("Relevant 2", "failure", HUNG_TRUSTED)
check(
  "a trusted-workflow-files checkout timeout",
  { "jobs" => [trusted], "annotations" => hang_annotations(trusted, "Check out trusted workflow files"), "conclusion" => "failure" },
  expect: :rerun
)

# Jobs with no `Run tests` step at all still qualify: no specs got the chance to
# run, so the re-run cannot be laundering a red suite.
build = job("Build images", "failure", [["Set up job", "success", 3], ["Check out repository", "failure", 300]])
check(
  "a job with no Run tests step at all",
  { "jobs" => [build], "annotations" => hang_annotations(build), "conclusion" => "failure" },
  expect: :rerun
)

# The one this exists to never do.
check(
  "a spec failure",
  { "jobs" => [job("Fast 4", "failure", SPEC_FAILURE)] },
  expect: :skip
)

check(
  "a docker login failure",
  { "jobs" => [job("Slow 1", "failure", [["Set up job", "success", 3], ["Log in to Docker Hub", "failure", 20]])] },
  expect: :skip
)

# Checkout cancelled seconds in, with no timeout anywhere on the attempt. Nothing
# here says a hang happened, so nothing gets re-run.
check(
  "a short cancelled checkout with no hang on the attempt",
  { "jobs" => [job("Fast 9", "cancelled", [["Set up job", "success", 3], ["Check out repository", "cancelled", 12]])] },
  expect: :skip
)

# test_fast is fail-fast, so one hang cancels siblings mid-`Run tests`. That
# cancellation is collateral, not evidence -- and the run still concluded
# `failure`, which is what separates this from the case below.
fast_hang = job("Fast 16", "failure", HUNG_CHECKOUT)
fast_cancelled = job("Fast 17", "cancelled", [["Check out repository", "success", 10], ["Run tests", "cancelled", 400]])
check(
  "a hang plus a sibling cancelled mid-Run tests",
  { "jobs" => [fast_hang, fast_cancelled], "annotations" => hang_annotations(fast_hang), "conclusion" => "failure" },
  expect: :rerun
)

# The same jobs, but the run was cancelled outright -- someone hit cancel, or a
# new push cancelled it in progress. Job-level `cancelled` is indistinguishable
# from fail-fast collateral, so the run conclusion is the only thing that tells
# them apart, and re-running a run that was thrown away is wasted CI.
cancelled_hang = job("Fast 16", "failure", HUNG_CHECKOUT)
cancelled_sibling = job("Fast 17", "cancelled", [["Check out repository", "success", 10], ["Run tests", "cancelled", 400]])
check(
  "a hang on a run that was cancelled outright",
  { "jobs" => [cancelled_hang, cancelled_sibling], "annotations" => hang_annotations(cancelled_hang), "conclusion" => "cancelled" },
  expect: :skip
)

# Same shape, except the sibling's specs actually failed. One real red blocks the
# whole verdict, hang or no hang.
blocked_hang = job("Fast 16", "failure", HUNG_CHECKOUT)
check(
  "a hang plus a sibling whose specs failed",
  { "jobs" => [blocked_hang, job("Fast 17", "failure", SPEC_FAILURE)], "annotations" => hang_annotations(blocked_hang) },
  expect: :skip
)

# Without the annotation, 300s is just a checkout that was slow and then failed,
# and a checkout failing for a real reason will keep failing.
check(
  "a 300s checkout with no timeout annotation",
  { "jobs" => [job("Slow 3", "failure", HUNG_CHECKOUT)] },
  expect: :skip
)

# A concurrency cancel: red, but nothing hung.
check(
  "a cancelled attempt that never scheduled a job",
  { "jobs" => [] },
  expect: :skip
)

# The workflow fetches annotations only for the ids this prints, so a candidate
# it misses can never be classified as a hang.
$count += 1
candidate = job("Slow 3", "failure", HUNG_CHECKOUT)
_, listed = run({ "jobs" => [candidate, job("Fast 1", "failure", SPEC_FAILURE)] }, "--candidates")
if listed.split.map(&:to_i) == [candidate["id"]]
  puts "  ok    --candidates lists only the checkout-timeout jobs"
else
  puts "  FAIL  --candidates lists only the checkout-timeout jobs"
  $failures << "--candidates: expected #{[candidate['id']].inspect}, got #{listed.strip.inspect}"
end

# --- The workflow's own gate ----------------------------------------------
#
# The 2-attempt cap lives in the job `if`, not in the classifier, so nothing
# above can catch its removal.

WORKFLOW = File.expand_path("../../.github/workflows/rerun-hung-checkout.yml", __dir__)

$count += 1
gate = YAML.load_file(WORKFLOW).fetch("jobs").fetch("rerun").fetch("if")
# `cancelled` has to stay out of the gate: fail-fast behind a hang still leaves
# the run `failure`, so anything `cancelled` was thrown away on purpose.
if gate.include?("run_attempt < 2") && gate.include?("conclusion == 'failure'") && !gate.include?("conclusion == 'cancelled'")
  puts "  ok    the workflow gate caps attempts and only runs on a failed run"
else
  puts "  FAIL  the workflow gate caps attempts and only runs on a failed run"
  $failures << "workflow gate: #{gate.inspect}"
end

puts
if $failures.empty?
  puts "#{$count} checks passed."
  exit 0
end

warn "#{$failures.size} of #{$count} checks FAILED:\n\n"
$failures.each { |f| warn "  #{f}\n\n" }
exit 1
