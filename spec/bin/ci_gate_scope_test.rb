#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the `scope` step of .github/workflows/tests.yml, which decides
# whether a Tests run uses the full Fast/Slow matrix or the trimmed
# Test Relevant set, from the `run-all-specs` label on the PR behind the
# pushed commit.
#
#   ruby spec/bin/ci_gate_scope_test.rb
#
# The step runs on `push` (and `pull_request_target`), which GitHub only ever
# executes from the default branch, so it cannot be exercised from a PR. The
# body is therefore extracted from the workflow HERE — never transcribed — and
# driven with a stubbed `gh`, the way a runner would run it.

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

WORKFLOW = File.expand_path("../../.github/workflows/tests.yml", __dir__)
BRANCH = { "GITHUB_EVENT_NAME" => "push", "GITHUB_REF" => "refs/heads/gumclaw/example" }.freeze

$failures = []
$count = 0

def check(name, got, expected)
  $count += 1
  ok = got == expected
  $failures << "#{name}: expected #{expected.inspect}, got #{got.inspect}" unless ok
  puts "#{ok ? 'ok  ' : 'FAIL'} #{name}"
end

def step_body(job, step_id)
  steps = YAML.load_file(WORKFLOW).fetch("jobs").fetch(job).fetch("steps")
  step = steps.find { |s| s["id"] == step_id }
  raise "no step id=#{step_id.inspect} in job #{job.inspect}" unless step

  step.fetch("run")
end

# Runs the real step body in a throwaway dir with a stub `gh` on PATH.
# Returns [parsed GITHUB_OUTPUT, Process::Status, combined output, gh call count].
def run_scope(stub, env)
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, "step.sh"), step_body("ci_gate", "scope"))
    calls = File.join(dir, "gh_calls")
    File.write(calls, "")
    File.write(File.join(dir, "gh"), <<~SH)
      #!/usr/bin/env bash
      echo "$*" >> "#{calls}"
      case "#{stub}" in
        labels) printf 'working\\nrun-all-specs\\n' ;;
        no-label) printf 'working\\n' ;;
        # The shape observed on gumroad#8579: the API answered with an empty
        # body, so `gh` exited non-zero with jq's parse error on stderr.
        fail) echo "unexpected end of JSON input" >&2; exit 1 ;;
      esac
    SH
    FileUtils.chmod(0o755, File.join(dir, "gh"))
    out = File.join(dir, "github_output")
    File.write(out, "")
    e = {
      "PATH" => "#{dir}:#{ENV.fetch('PATH', '')}",
      "GITHUB_OUTPUT" => out,
      "GITHUB_REPOSITORY" => "antiwork/gumroad",
      "SHA" => "f" * 40,
    }.merge(BRANCH).merge(env)
    # `-e` matches the runner's `shell: /usr/bin/bash -e {0}`.
    combined, status = Open3.capture2e(e, "bash", "-e", File.join(dir, "step.sh"))
    outputs = File.readlines(out, chomp: true).to_h { |line| line.split("=", 2) }
    [outputs, status, combined, File.readlines(calls).size]
  end
end

out, status, _, calls = run_scope("labels", {})
check("run-all-specs on the PR runs the full suite", out["full"], "true")
check("a labelled lookup ends the step green", status.success?, true)
check("a labelled lookup is not retried", calls, 1)

out, = run_scope("no-label", {})
check("a PR without the label takes the trimmed set", out["full"], "false")

out, status, log, calls = run_scope("fail", {})
check("a failed label lookup runs the FULL suite, not the trimmed set", out["full"], "true")
check("a failed lookup still ends the step green", status.success?, true)
check("a failed lookup is retried three times", calls, 3)
check("a failed lookup warns in the job log", log.include?("::warning::"), true)

# A push to main is the full suite by definition — it must not depend on the
# API at all, so it is checked with the failing stub.
out, = run_scope("fail", "GITHUB_EVENT_NAME" => "push", "GITHUB_REF" => "refs/heads/main")
check("a push to main runs the full suite without reading any labels", out["full"], "true")

puts
if $failures.empty?
  puts "#{$count} checks passed."
  exit 0
end

warn "#{$failures.size} of #{$count} checks FAILED:\n\n"
$failures.each { |f| warn "  #{f}\n\n" }
exit 1
