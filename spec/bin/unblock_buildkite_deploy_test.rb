#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/unblock-buildkite-deploy, against a stub curl on PATH.
#
#   ruby spec/bin/unblock_buildkite_deploy_test.rb

require "json"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("../../bin/unblock-buildkite-deploy", __dir__)
SHA = "fbf8836d0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

$failures = []
$count = 0

# The stub answers by URL: the builds list, one build's detail, or the unblock
# PUT, and records each call so a check can see whether the PUT happened.
STUB = <<~'SH'
  #!/usr/bin/env bash
  echo "$*" >> "$STUB_DIR/calls"
  args="$*"
  if [[ "$args" == *"-X PUT"* ]]; then
    printf '%s' "$STUB_PUT_CODE"
  elif [[ "$args" == *"/builds?commit="* ]]; then
    cat "$STUB_DIR/builds.json"
  else
    cat "$STUB_DIR/build.json"
  fi
SH

def gate_job(state)
  { "type" => "manual", "step_key" => "require-approval", "state" => state, "id" => "job-1" }
end

def run_script(builds:, build: { "jobs" => [] }, put_code: "200")
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, "curl"), STUB)
    File.chmod(0o755, File.join(dir, "curl"))
    File.write(File.join(dir, "builds.json"), JSON.dump(builds))
    File.write(File.join(dir, "build.json"), JSON.dump(build))
    env = {
      "PATH" => "#{dir}:#{ENV.fetch('PATH')}", "STUB_DIR" => dir, "STUB_PUT_CODE" => put_code,
      "BUILDKITE_API_TOKEN" => "token", "COMMIT_SHA" => SHA, "ORG_SLUG" => "org", "PIPELINE_SLUG" => "pipe"
    }
    _, status = Open3.capture2e(env, "bash", SCRIPT)
    calls = File.exist?(File.join(dir, "calls")) ? File.read(File.join(dir, "calls")) : ""
    [status.exitstatus, calls.include?("-X PUT")]
  end
end

def check(name, expect_code:, expect_put:, **options)
  $count += 1
  code, put = run_script(**options)
  if code == expect_code && put == expect_put
    puts "  ok    #{name}"
  else
    puts "  FAIL  #{name}"
    $failures << "#{name}: expected exit #{expect_code} put=#{expect_put}, got exit #{code} put=#{put}"
  end
end

puts "unblock-buildkite-deploy"

blocked_build = [{ "commit" => SHA, "state" => "blocked", "number" => 25153, "created_at" => "2026-10-06T14:55:30Z" }]

check("a blocked gate is unblocked", builds: blocked_build, build: { "jobs" => [gate_job("blocked")] }, expect_code: 0, expect_put: true)
check("an unblocked gate needs nothing", builds: blocked_build, build: { "jobs" => [gate_job("unblocked")] }, expect_code: 0, expect_put: false)
check("a gate that is not there yet is retried", builds: blocked_build, build: { "jobs" => [] }, expect_code: 1, expect_put: false)
check("no build for the commit is retried", builds: [], expect_code: 1, expect_put: false)
check(
  "a build for another commit does not count",
  builds: [blocked_build.first.merge("commit" => "other")], expect_code: 1, expect_put: false
)
check(
  "a finished build does not count",
  builds: [blocked_build.first.merge("state" => "passed")], expect_code: 1, expect_put: false
)
check(
  "a failed unblock request is retried",
  builds: blocked_build, build: { "jobs" => [gate_job("blocked")] }, put_code: "500", expect_code: 1, expect_put: true
)
check(
  "a network error on the unblock request is retried",
  builds: blocked_build, build: { "jobs" => [gate_job("blocked")] }, put_code: "000", expect_code: 1, expect_put: true
)

puts
if $failures.empty?
  puts "#{$count} checks passed."
  exit 0
end

warn "#{$failures.size} of #{$count} checks FAILED:\n\n"
$failures.each { |f| warn "  #{f}\n\n" }
exit 1
