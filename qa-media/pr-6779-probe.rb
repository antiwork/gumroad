# frozen_string_literal: true

# QA probe for PR #6779 (report partial order-charge failures to Sentry).
# Non-visual head: no presenter, view, or JS reads anything this diff touches (verified by
# `git diff --name-only origin/main...<head> -- app/javascript app/views app/presenters` = empty),
# so the deliverable is a transcript. Each row is produced on the pod, and the "BEFORE" column
# re-implements the PREVIOUS rescue body on the SAME inputs in the SAME process.
def mark(k, v) = puts("MARK #{k}=#{v}")

mark "revision", ENV["REVISION"].to_s[0, 12].inspect

# ---- 1. Structure: the notify really is inside the PER-GROUP rescue (the body's core claim) ----
# Anchor on the FIRST rescue after the loop opens, not on the last rescue in the file: there is an
# unrelated `rescue => e` at 168 inside a later method, and `Error charging order` also appears in
# the raise on 52. Both broke a naive max()/index() scan on the first run of this probe.
src = File.read(Rails.root.join("app/services/order/charge_service.rb")).lines
each_i = src.index { _1.include?("purchases_by_seller.each do") }
resc_i = (each_i...src.size).find { src[_1].strip == "rescue => e" }
notify_i = (resc_i...src.size).find { src[_1].include?("ErrorNotifier.notify") }
log_i    = (resc_i...src.size).find { src[_1].include?("Rails.logger.error") }
ens_i    = (resc_i...src.size).find { src[_1].strip == "ensure" }
end_i    = (ens_i...src.size).find { src[_1].strip == "end" }
mark "lines", { each: each_i + 1, rescue: resc_i + 1, log: log_i + 1,
                notify: notify_i + 1, ensure: ens_i + 1, loop_end: end_i + 1 }.inspect
mark "notify_inside_per_group_rescue",
     (each_i < resc_i && resc_i < log_i && log_i < notify_i && notify_i < ens_i && ens_i < end_i)
mark "rescue_reraises", src[(resc_i + 1)...ens_i].any? { _1.strip.start_with?("raise") }
mark "unrelated_rescue_lines_ignored",
     src.each_index.select { src[_1].strip == "rescue => e" }.map { _1 + 1 }.reject { _1 == resc_i + 1 }.inspect

# 628aa53e9 wraps the notify in its own begin/rescue so a raising notifier cannot abort the
# seller loop. Assert that guard is present and that it, too, does not re-raise.
guard_begin = (resc_i...ens_i).find { src[_1].strip == "begin" }
guard_resc  = guard_begin && (guard_begin...ens_i).find { src[_1].strip.start_with?("rescue =>") }
guard_body  = guard_resc ? src[(guard_resc + 1)...ens_i] : []
mark "notify_guarded", !guard_resc.nil?
mark "notify_guard_lines", guard_resc ? { begin: guard_begin + 1, rescue: guard_resc + 1 }.inspect : "ABSENT"
mark "notify_guard_reraises", guard_body.any? { _1.strip.start_with?("raise") }
mark "notify_guard_logs", guard_body.any? { _1.include?("Rails.logger.error") }

# ---- 2. notify signature: bare kwargs must land in Sentry's extra context ----
mark "notify_params", ErrorNotifier.method(:notify).parameters.inspect
mark "sentry_client_present", !Sentry.get_current_client.nil?
mark "sentry_dsn_present", Sentry.configuration&.dsn.present?

# ---- 3. Behaviour grid: does the notify change control flow? ----
# Replica of the loop shape, two seller groups, group 1 raises. AFTER = this head's rescue body,
# BEFORE = the previous body (log only). Both run on the same inputs, same process.
LOGGED = []
SENTRY = []
real_notify = ErrorNotifier.method(:notify)
real_error  = Rails.logger.method(:error)
ErrorNotifier.singleton_class.define_method(:notify) { |e, **ctx| SENTRY << [e.class.name, ctx]; :recorded }
Rails.logger.singleton_class.define_method(:error) { |m| LOGGED << m.to_s[0, 48]; true }

ORDER_ID = 4242
GROUPS   = { 11 => :raises, 22 => :succeeds }

def drive(groups, order_id, rescue_body)
  charged  = []
  ensured  = []
  groups.each do |seller_id, behaviour|
    raise StandardError, "Mixed merchant accounts in purchases" if behaviour == :raises
    charged << seller_id
  rescue => e
    rescue_body.call(e, order_id, seller_id)
  ensure
    ensured << seller_id
  end
  [charged, ensured]
end

AFTER = lambda do |e, oid, sid|
  Rails.logger.error("Error charging order (#{oid}):: #{e.class} => #{e.message}")
  begin
    ErrorNotifier.notify(e, order_id: oid, seller_id: sid)
  rescue => notify_error
    Rails.logger.error("Error reporting charge failure for order (#{oid}):: " \
                       "#{notify_error.class} => #{notify_error.message}")
  end
end
# The head BEFORE 628aa53e9: notify called bare, so a raising notifier escapes the rescue
# clause and aborts the whole loop. This is the arm 628aa53e9 exists to fix.
PREV_HEAD = lambda do |e, oid, sid|
  Rails.logger.error("Error charging order (#{oid}):: #{e.class} => #{e.message}")
  ErrorNotifier.notify(e, order_id: oid, seller_id: sid)
end
BEFORE = lambda do |e, oid, _sid|
  Rails.logger.error("Error charging order (#{oid}):: #{e.class} => #{e.message}")
end

# --- 3a. Healthy notifier: the three arms must be indistinguishable except for sentry count
[["AFTER (this head)", AFTER], ["PREV (666e562dc, bare notify)", PREV_HEAD],
 ["ORIGINAL (log only)", BEFORE]].each do |label, body|
  LOGGED.clear
  SENTRY.clear
  aborted = false
  charged, ensured = begin
    drive(GROUPS, ORDER_ID, body)
  rescue StandardError
    aborted = true
    [[], []]
  end
  mark "flow_healthy", "#{label} | loop_aborted=#{aborted} charged_sellers=#{charged.inspect} " \
                       "ensure_ran_for=#{ensured.inspect} logged=#{LOGGED.size} " \
                       "sentry_events=#{SENTRY.size} sentry_ctx=#{SENTRY.first&.last.inspect}"
end

# --- 3b. RAISING notifier: this is the whole point of 628aa53e9. Same grid, notify blows up.
ErrorNotifier.singleton_class.define_method(:notify) do |_e, **_ctx|
  raise Timeout::Error, "sentry transport down"
end
[["AFTER (this head)", AFTER], ["PREV (666e562dc, bare notify)", PREV_HEAD],
 ["ORIGINAL (log only)", BEFORE]].each do |label, body|
  LOGGED.clear
  aborted = false
  charged, ensured = begin
    drive(GROUPS, ORDER_ID, body)
  rescue StandardError
    aborted = true
    [[], []]
  end
  mark "flow_notifier_raises", "#{label} | loop_aborted=#{aborted} charged_sellers=#{charged.inspect} " \
                               "ensure_ran_for=#{ensured.inspect} logged=#{LOGGED.size} " \
                               "log_tail=#{LOGGED.last.inspect}"
end
ErrorNotifier.singleton_class.define_method(:notify) { |e, **ctx| SENTRY << [e.class.name, ctx]; :recorded }

ErrorNotifier.singleton_class.define_method(:notify) { |*a, **k| real_notify.call(*a, **k) }
Rails.logger.singleton_class.define_method(:error) { |*a| real_error.call(*a) }

# ---- 4. Reachability controls: which exception classes can actually arrive here ----
# Read from Charge::CreateService, which is what makes "declines never reach this rescue" checkable.
cs = File.read(Rails.root.join("app/services/charge/create_service.rb")).lines
# Scan each rescue clause up to the NEXT rescue/ensure at the same indentation. A fixed
# 12-line window stopping at the first bare `end` is wrong: every one of these clauses
# contains a `purchases.each do ... end`, whose `end` truncates the window BEFORE the
# `raise e` on the rate-limit clause — which silently reported zero reaching classes on
# the first run of this probe.
rescue_idx = cs.each_index.select { cs[_1].match?(/^\s*rescue\s+\w+\s*=>/) }
rescued = {}
rescue_idx.each_with_index do |i, n|
  klass = cs[i].match(/^\s*rescue\s+(\w+)\s*=>/)[1]
  indent = cs[i][/\A\s*/].length
  stop = rescue_idx[n + 1] ||
         (i...cs.size).find { |j| j > i && cs[j].match?(/\A\s{#{indent}}(ensure|end)\b/) } ||
         cs.size
  body = cs[(i + 1)...stop]
  rescued[klass] = { reraises: body.any? { _1.strip.match?(/\Araise\s+e\b/) },
                     body_lines: body.size }
end
mark "create_service_rescue_map", rescued.transform_values { _1[:reraises] }.inspect
rescued.each do |klass, info|
  mark "control", "#{klass} rescued_in_create_service=true reraised=#{info[:reraises]} " \
                  "reaches_order_rescue=#{info[:reraises]} clause_body_lines=#{info[:body_lines]}"
end
mark "reaching_classes", rescued.select { |_, v| v[:reraises] }.keys.inspect
mark "swallowed_classes_count", rescued.count { |_, v| !v[:reraises] }

mark "DONE", 1
