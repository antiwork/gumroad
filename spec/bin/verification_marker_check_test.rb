#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/verification-marker-check.
#
# Plain ruby, no Rails and no bundle: the checker only ever sees a `gh pr view` payload, and it is
# the file that decides the `verification/ready` check, so this pins the exit codes and the wording
# a PR author is going to act on.
#
#   ruby spec/bin/verification_marker_check_test.rb

require "json"
require "open3"
require "tempfile"

CHECKER = File.expand_path("../../bin/verification-marker-check", __dir__)
TEMPLATE = File.expand_path("../../.github/pull_request_template.md", __dir__)
SHA = "a" * 40

$failures = []
$count = 0

def assert(condition, message)
  $count += 1
  $failures << message unless condition
end

def run_with(pr)
  Tempfile.create(["pr", ".json"]) do |file|
    file.write(JSON.generate(pr))
    file.flush
    out, err, status = Open3.capture3("python3", CHECKER, file.path)
    [status.exitstatus, out, err]
  end
end

def run_env(body:, head: SHA, draft: false, files: [])
  env = { "PR_BODY" => body, "PR_HEAD" => head, "PR_DRAFT" => draft.to_s, "PR_FILES" => files.join("\n") }
  out, err, status = Open3.capture3(env, "python3", CHECKER)
  [status.exitstatus, out, err]
end

def pr(body, files: ["app/models/user.rb"], draft: false, head: SHA)
  { "body" => body, "headRefOid" => head, "isDraft" => draft,
    "files" => files.map { |path| { "path" => path } } }
end

def verified(sha: SHA, ran: "bin/rspec spec/models/user_spec.rb", saw: "12 examples, 0 failures")
  "Verification: verified @ #{sha} (ran: #{ran}; saw: #{saw})"
end

code, out, = run_with(pr(verified))
assert(code.zero?, "a marker at head clears (got #{code})")
assert(out.include?("12 examples, 0 failures"), "the clearing line echoes what was seen: #{out.inspect}")

code, _, err = run_with(pr(verified(sha: "b" * 40)))
assert(code == 1, "a marker pinned to another commit is owed (got #{code})")
assert(err.include?("older commit"), "and says the pin is stale: #{err.inspect}")

code, _, err = run_with(pr("Just prose, no marker."))
assert(code == 1, "no marker is owed (got #{code})")
assert(err.include?("verification/ready:"), "the failure leads with the check name: #{err.inspect}")

code, = run_with(pr(verified(ran: "n/a", saw: "none")))
assert(code == 1, "a hollow receipt is owed (got #{code})")

code, = run_with(pr(verified(ran: "bin/rspec", saw: "")))
assert(code == 1, "a missing saw: is owed (got #{code})")

doc_only = ["CONTRIBUTING.md", ".agents/skills/verify-pr/SKILL.md"]
code, = run_with(pr("Verification: exempt (docs + skill) @ #{SHA}", files: doc_only))
assert(code.zero?, "exempt clears a documentation-only diff (got #{code})")

code, _, err = run_with(pr("Verification: exempt (docs) @ #{SHA}"))
assert(code == 1, "exempt is refused when the diff changes code (got #{code})")
assert(err.include?("app/models/user.rb"), "and names the path that needs a real receipt: #{err.inspect}")

code, = run_with(pr("nothing at all", draft: true))
assert(code.zero?, "a draft is skipped (got #{code})")

out, err, status = Open3.capture3("python3", CHECKER, "--self-test")
assert(status.exitstatus.zero?, "the checker's own self-test passes: #{err}")

# The shipped template must not satisfy the gate by itself: a PR created from it and never filled in
# has to be told what is missing.
body = File.read(TEMPLATE)
code, = run_env(body: body, files: ["app/models/user.rb"])
assert(code == 1, "the unfilled PR template is owed (got #{code})")

code, = run_env(body: verified, files: ["app/models/user.rb"])
assert(code.zero?, "the environment input path clear (got #{code})")

if $failures.empty?
  puts "verification-marker-check: #{$count} assertions OK"
else
  warn "FAILED #{$failures.size}/#{$count}"
  $failures.each { |failure| warn "  - #{failure}" }
  exit 1
end
