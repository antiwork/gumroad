#!/usr/bin/env ruby
# frozen_string_literal: true

# auto_merge_gate.rb
#
# Decides whether a PR is ELIGIBLE for unattended auto-merge on the "safe lane".
#
# Deterministic by design: an AI agent may DRAFT the fix, but the merge
# decision itself is made by inspectable rules here — there is no model
# judgment anywhere in the merge path. A PR only becomes a candidate when it
# is a small, bot-authored, ticket-scoped fix that touches no sensitive code.
#
#   Exit 0 (GREEN) => eligible for safe-lane auto-merge.
#   Exit 1 (RED)   => blocked; routes to the human one-tap approval lane.
#
# Usage (CI):
#   ruby scripts/auto_merge_gate.rb \
#     --base-sha "$BASE_SHA" --head-sha "$HEAD_SHA" \
#     --author "$PR_AUTHOR" --labels "$PR_LABELS"
#
# Reads the diff via `git diff --numstat base...head`, so the workflow must
# check out with enough history to resolve both SHAs (fetch-depth: 0).

require "optparse"

# ---- Tunables (intentionally conservative; loosen only with evidence) ----
MAX_LINES_CHANGED = 40
MAX_FILES_CHANGED = 5
BOT_AUTHOR        = "gumclaw"
REQUIRED_LABEL    = "support-fix"

# Any changed file matching ANY of these patterns blocks the merge.
# Covers money, auth, fraud/risk, schema/data migrations, infra/CI, deps —
# anything where an unattended change could move money or break checkout.
SENSITIVE_PATTERNS = [
  %r{\Aapp/models/(charge|purchase|payment|subscription|balance|refund|credit|payout)}i,
  %r{\Aapp/services/.*(payment|payout|charge|risk|fraud|stripe|paypal|tax)}i,
  %r{\Aapp/services/risk}i,
  %r{payments?/}i,
  %r{stripe}i,
  %r{paypal}i,
  %r{webhook}i,
  %r{\Adb/migrate/},
  %r{\Adb/schema\.rb\z},
  %r{\Aconfig/},
  %r{devise}i,
  %r{\Aapp/controllers/.*(session|auth|login|oauth|admin)}i,
  %r{\AGemfile(\.lock)?\z},
  %r{package(-lock)?\.json\z},
  %r{yarn\.lock\z},
  %r{\A\.github/},                 # never let the loop edit its own CI
  %r{\Ascripts/auto_merge_gate},   # never let it edit the gate itself
].freeze

def block!(reason)
  puts "🔴 auto-merge-gate: BLOCKED"
  puts "   reason: #{reason}"
  puts "   → routing to human one-tap approval lane"
  exit 1
end

def allow!(files:, lines:, author:)
  puts "🟢 auto-merge-gate: ELIGIBLE for safe-lane auto-merge"
  puts "   files=#{files} lines=#{lines} author=#{author}"
  exit 0
end

options = {}
OptionParser.new do |o|
  o.on("--base-sha SHA") { |v| options[:base] = v }
  o.on("--head-sha SHA") { |v| options[:head] = v }
  o.on("--author A")     { |v| options[:author] = v }
  o.on("--labels L")     { |v| options[:labels] = v.to_s }
end.parse!

base   = options[:base]  || abort("--base-sha required")
head   = options[:head]  || abort("--head-sha required")
author = options[:author].to_s
labels = options[:labels].to_s.split(/[,\s]+/).map(&:strip).reject(&:empty?)

# 1) Provenance — only bot-authored, ticket-scoped fixes are candidates.
block!("author '#{author}' is not the bot (#{BOT_AUTHOR})") unless author == BOT_AUTHOR
block!("missing required label '#{REQUIRED_LABEL}'")        unless labels.include?(REQUIRED_LABEL)

# 2) Diff analysis.
numstat = `git diff --numstat #{base}...#{head}`.strip
block!("empty or unreadable diff") if numstat.empty?

files = []
total_lines = 0
numstat.each_line do |line|
  added, deleted, path = line.strip.split("\t", 3)
  next if path.nil?
  # binary files report "-" for added/deleted counts.
  block!("binary file change: #{path}") if added == "-" || deleted == "-"
  files << path
  total_lines += added.to_i + deleted.to_i
end

# 3) Sensitive-path veto.
files.each do |path|
  SENSITIVE_PATTERNS.each do |re|
    block!("touches sensitive path: #{path}") if path =~ re
  end
end

# 4) Size ceilings.
block!("too many files (#{files.size} > #{MAX_FILES_CHANGED})")   if files.size > MAX_FILES_CHANGED
block!("too many lines (#{total_lines} > #{MAX_LINES_CHANGED})")  if total_lines > MAX_LINES_CHANGED

allow!(files: files.size, lines: total_lines, author: author)
