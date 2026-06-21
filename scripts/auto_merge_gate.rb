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
SHA_RE = /\A[0-9a-f]{7,40}\z/
# The bot account whose VERIFIED signature authorizes the safe lane. Compared
# against each commit's GitHub-resolved signer login (.author.login on a
# verified commit), supplied by the trusted caller — never the PR author field.
BOT_IDENTITY = "gumclaw"

# ALLOWLIST (default-deny): a PR is eligible ONLY if EVERY changed path matches
# one of these safe prefixes. Anything outside the allowlist => block. This is
# the inverse of a denylist and fails closed on unknown/new code areas.
SAFE_PATH_ALLOWLIST = [
  %r{\Aapp/views/help_center/articles/contents/},
  %r{\A(README|CHANGELOG)\.md\z},
  %r{\Adocs/},
].freeze

# DENYLIST (hard block): critical paths with real production blast radius —
# money movement, auth, data shape, config, secrets, dependencies, CI, and the
# gate itself. Evaluated BEFORE the allowlist so a deny ALWAYS wins. Today this
# is redundant with the default-deny allowlist, but it is a durable tripwire: if
# the allowlist is ever broadened, none of these can reach unattended merge.
SENSITIVE_PATH_DENYLIST = [
  # Payments core: charging, payouts, transfers, refunds, disputes, merchant
  # registration, sales tax, raw card data.
  %r{\Aapp/business/payments/},
  %r{\Aapp/business/sales_tax/},
  %r{\Aapp/business/card_data_handling/},
  # Money/auth models (charge, refund, dispute, payout, balance, payment,
  # purchase, credit, subscription, bank account, merchant, fraud, tax).
  %r{\Aapp/models/concerns/(balance|charge|payment)/},
  %r{\Aapp/models/.*(charge|refund|dispute|chargeback|payout|balance|payment|purchase|credit|subscription|bank|merchant|fraud|recurring_service|tax)},
  # Payment/fraud/subscription services and money exports.
  %r{\Aapp/services/(charge|dispute_evidence|early_fraud_warning|subscription)/},
  %r{\Aapp/services/exports/(payouts|tax_summary)/},
  # Legacy payment/subscription modules.
  %r{\Aapp/modules/(payment|subscription)/},
  # Money/auth/admin/webhook controllers.
  %r{\Aapp/controllers/(admin|oauth|payouts|subscriptions|stripe|settings)/},
  %r{\Aapp/controllers/api/internal/admin/},
  %r{\Aapp/controllers/.*(webhook|paypal|stripe|ipn|events_controller|sessions_controller|users_controller|application_controller)},
  # Authorization policies for money/admin/settings.
  %r{\Aapp/policies/(admin|settings)/},
  # Admin & payment frontend (server enforces logic, but block the surface too).
  %r{\Aapp/javascript/(components|pages)/Admin/},
  %r{\Aapp/javascript/(components|pages)/(Settings/Payments|Payout|Subscriptions)},
  # Database schema, migrations, seeds.
  %r{\Adb/},
  # Application config, secrets, certs, routes, initializers, credentials.
  %r{\Aconfig/},
  # Dependency manifests / lockfiles.
  %r{\A(Gemfile(\.lock)?|package(-lock)?\.json|yarn\.lock)\z},
  # CI / automation / the gate itself — no self-widening of authority.
  %r{\A\.github/},
  %r{\Ascripts/auto_merge_gate},
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
block!("missing/invalid --base-sha") unless SHA_RE.match?(base)
block!("missing/invalid --head-sha") unless SHA_RE.match?(head)

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

# (3) Deny wins over allow: any critical path hard-blocks the PR, even if a
# future allowlist change would match it. Then default-deny: every remaining
# path must be inside the safe allowlist.
files.each do |path|
  if SENSITIVE_PATH_DENYLIST.any? { |re| path =~ re }
    block!("critical path blocked by denylist: #{path}")
  end
  unless SAFE_PATH_ALLOWLIST.any? { |re| path =~ re }
    block!("path outside safe allowlist: #{path}")
  end
end

block!("too many files (#{files.size} > #{MAX_FILES_CHANGED})") if files.size > MAX_FILES_CHANGED
block!("too many lines (#{total} > #{MAX_LINES_CHANGED})")      if total > MAX_LINES_CHANGED

pass!(files: files.size, lines: total, signer: signers.uniq.join(","))
