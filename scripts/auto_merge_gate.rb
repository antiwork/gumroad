#!/usr/bin/env ruby
# frozen_string_literal: true

# auto-merge-gate
#
# Decides whether a PR is ELIGIBLE for unattended auto-merge on the "safe lane".
# Deterministic by design: a model drafts the fix, but the merge decision is
# inspectable rules — no LLM judgment in the merge path.
#
# ─────────────────────────────────────────────────────────────────────────────
# SECURITY MODEL (read before changing the wiring)
#
#   This script is a SECURITY BOUNDARY. It MUST be executed from TRUSTED code —
#   i.e. the copy of this file on the protected base branch (main) — and NEVER
#   from the PR's own checkout. If it runs from the PR checkout, the PR under
#   judgment can rewrite the gate to always pass, which defeats the entire
#   purpose (self-refuting check).
#
#   Enforced by the caller (the trusted support-to-ship cron OR a
#   `workflow_run`-triggered job that checks out `main`), which:
#     1. checks out THIS script from the base/main ref,
#     2. fetches the PR's verified metadata via the API (not from PR files),
#     3. runs the diff against the PR head,
#     4. posts the commit status.
#
#   The gate also requires per-commit verification: every commit on the PR must
#   be verified-signed by the bot identity. The PR "author" field and labels are
#   NOT treated as authorization (both are spoofable / mutable by the PR).
# ─────────────────────────────────────────────────────────────────────────────
#
# Exit 0 (GREEN) => eligible: small, signed-by-bot, ticket-scoped fix touching
#                   ONLY allowlisted safe paths.
# Exit 1 (RED)   => blocked: routes to the one-tap human-approval lane.
#
# Usage (from trusted context only):
#   ruby auto_merge_gate.rb --base-sha SHA --head-sha SHA \
#     --commit-signers "gumclaw,gumclaw" --label-verified true

require "optparse"
require "open3"

# ---- Tunables (start conservative; loosen only with evidence) ----
MAX_LINES_CHANGED = 40
MAX_FILES_CHANGED = 5
SHA_RE = /\A[0-9a-f]{7,40}\z/.freeze
# The bot account whose VERIFIED signature authorizes the safe lane. Compared
# against each commit's GitHub-resolved signer login (.author.login on a
# verified commit), supplied by the trusted caller — never the PR author field.
BOT_IDENTITY = "gumclaw"

# ALLOWLIST (default-deny): a PR is eligible ONLY if EVERY changed path matches
# one of these safe prefixes. Anything outside the allowlist => block. This is
# the inverse of a denylist and fails closed on unknown/new code areas.
SAFE_PATH_ALLOWLIST = [
  %r{\Aapp/services/support/},
  %r{\Aapp/views/support/},
  %r{\Aapp/javascript/components/support/}i,
  %r{\Aapp/helpers/support/},
  %r{\Aspec/services/support/},
  %r{\Aspec/views/support/},
  %r{\Aconfig/locales/support\.[a-z-]+\.yml\z},
  %r{\A(README|CHANGELOG)\.md\z},
  %r{\Adocs/},
].freeze

def block!(reason)
  puts "🔴 auto-merge-gate: BLOCKED"
  puts "   reason: #{reason}"
  puts "   → routing to human-approval lane"
  exit 1
end

def pass!(stats)
  puts "🟢 auto-merge-gate: ELIGIBLE for safe-lane auto-merge"
  puts "   files=#{stats[:files]} lines=#{stats[:lines]} signed_by=#{stats[:signer]}"
  exit 0
end

options = {}
OptionParser.new do |o|
  o.on("--base-sha SHA")        { |v| options[:base] = v }
  o.on("--head-sha SHA")        { |v| options[:head] = v }
  o.on("--commit-signers LIST") { |v| options[:signers] = v.to_s }
  o.on("--label-verified BOOL") { |v| options[:label] = (v == "true") }
end.parse!

base = options[:base].to_s
head = options[:head].to_s
block!("missing/invalid --base-sha") unless base =~ SHA_RE
block!("missing/invalid --head-sha") unless head =~ SHA_RE

# (4) Authorization comes from VERIFIED commit signatures supplied by the trusted
# caller (from the GitHub API `verification.verified` + signer), not from the
# mutable PR author field. Every commit must be bot-signed.
signers = options[:signers].to_s.split(",").map(&:strip)
block!("no verified commit signers provided") if signers.empty?
unless signers.all? { |s| s == BOT_IDENTITY }
  block!("not all commits verified-signed by bot (signers=#{signers.uniq.join(',')})")
end
# Label is a SECONDARY scoping signal, verified by the trusted caller via API.
block!("support-fix label not present/verified") unless options[:label]

# (2) Parse the diff with quoting disabled and NUL separators so no path can
# dodge the matchers via git's octal/quote escaping or embedded whitespace.
# (1) The caller guarantees this runs against trusted git state.
out, status = Open3.capture2(
  "git", "-c", "core.quotePath=false",
  "diff", "--numstat", "-z", "--no-renames", "#{base}...#{head}"
)
block!("git diff failed (#{status.exitstatus})") unless status.success?
block!("empty or unreadable diff") if out.strip.empty?

# numstat -z format: "added\tdeleted\tpath\0" repeated.
files = []
total = 0
out.split("\0").each do |rec|
  next if rec.empty?
  added, deleted, path = rec.split("\t", 3)
  next if path.nil? || path.empty?
  block!("binary file change: #{path}") if added == "-" || deleted == "-"
  files << path
  total += added.to_i + deleted.to_i
end
block!("no file changes parsed") if files.empty?

# (3) Default-deny: every path must be inside the safe allowlist.
files.each do |path|
  unless SAFE_PATH_ALLOWLIST.any? { |re| path =~ re }
    block!("path outside safe allowlist: #{path}")
  end
end

block!("too many files (#{files.size} > #{MAX_FILES_CHANGED})") if files.size > MAX_FILES_CHANGED
block!("too many lines (#{total} > #{MAX_LINES_CHANGED})")      if total > MAX_LINES_CHANGED

pass!(files: files.size, lines: total, signer: signers.uniq.join(","))
