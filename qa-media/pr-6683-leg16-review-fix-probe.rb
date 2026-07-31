# frozen_string_literal: true

TAG = "qa6683r16"
RUN = SecureRandom.hex(3)
def mark(k, v) = puts("MARK #{k}=#{v}")
mark "RUN", RUN
mark "REVISION", `cat /app/REVISION 2>/dev/null`.strip
$redis.keys("stripe_guardian_sync*").each { |k| $redis.del(k) }

S = GdprDataErasureService
M = StripeGuardianManager
ADMIN = User.find_by(email: "seller@gumroad.com") || User.first
SGM_SRC  = File.read(Rails.root.join("app/business/payments/merchant_registration/implementations/stripe/stripe_guardian_manager.rb"))
GDPR_SRC = File.read(Rails.root.join("app/services/gdpr_data_erasure_service.rb"))
JOB_SRC  = File.read(Rails.root.join("app/sidekiq/delete_guardian_stripe_person_job.rb"))

# ---- the commits' surfaces, present at the served revision -------------------
mark "SRC_reconcile_outside_branch", SGM_SRC[/def self\.sync.*?^  end$/m].to_s.scan(/reconcile_duplicate_persons!/).size == 1 &&
  SGM_SRC[/result =\n(.*?)\n\n(.*?)reconcile_duplicate_persons!\(guardian, stripe_account\.id\)/m] ? true : false
mark "SRC_per_orphan_rescue", SGM_SRC[/def self\.reconcile_duplicate_persons!.*?private_class_method/m].to_s.scan(/rescue => e/).size
mark "SRC_existing_person_code_gate", SGM_SRC[/def self\.existing_person.*?private_class_method/m].to_s.include?('raise unless e.code == "resource_missing"')
mark "SRC_retry_interval", M::SYNC_LOCK_RETRY_INTERVAL_SECONDS
mark "SRC_no_thread_new", !SGM_SRC.include?("Thread.new")
mark "SRC_erasure_guardian_gate", GDPR_SRC.include?("if @user.guardians.exists?")
mark "SRC_unresolvable_predicate", GDPR_SRC.include?("def unresolvable_stripe_merchant_rows?")
# Source ORDER, not mere presence: index, because the whole point of the commit is which line runs first.
mark "SRC_note_before_enqueue", GDPR_SRC.index("record_incomplete_erasure_note!(person_ids)") < GDPR_SRC.index("person_ids.each do |stripe_person_id|")
mark "SRC_job_note_before_notify", JOB_SRC.index("add_payout_note") < JOB_SRC.index("ErrorNotifier.notify(content)")
raise "ABORT reconcile not hoisted out of the create branch" unless SGM_SRC[/def self\.sync.*?^  end$/m].to_s.include?("reconcile_duplicate_persons!(guardian, stripe_account.id)\n      result")
raise "ABORT per-orphan rescue absent" unless SGM_SRC[/each_legal_guardian_person\(stripe_account_id\) do \|person\|.*?^    end$/m].to_s.include?("rescue => e")
raise "ABORT erasure guardian gate absent" unless GDPR_SRC.include?("if @user.guardians.exists?")
raise "ABORT unresolvable predicate absent" unless GDPR_SRC.include?("def unresolvable_stripe_merchant_rows?")

def seed(label, minor: true, guardian: true)
  u = User.new(email: "#{TAG}-#{label}-#{SecureRandom.hex(4)}@example.com",
               username: "#{TAG}#{label}#{SecureRandom.hex(3)}".downcase, name: "QA6683r16 #{label}")
  u.password = SecureRandom.hex(12); u.save!(validate: false)
  g = nil
  if guardian
    g = Guardian.new(user: u, first_name: "Dana", last_name: "Guardian",
                     email: "#{TAG}-#{label}-g@example.com", phone: "+15551234567",
                     date_of_birth: Date.new(1980, 4, 12), street_address: "1 Guardian Way",
                     city: "San Francisco", state: "CA", zip_code: "94107", country: "United States",
                     stripe_tos_accepted: true, stripe_tos_ip: "104.28.0.1",
                     stripe_tos_accepted_at: Time.utc(2026, 7, 1, 12, 0, 0))
    g.individual_tax_id = "000000000"; g.save!; g.reload
  end
  uci = UserComplianceInfo.new(user: u, first_name: "Robin", last_name: "Minor",
                               street_address: "2 Minor St", city: "San Francisco", state: "CA",
                               zip_code: "94107", country: "United States",
                               birthday: (minor ? 15.years.ago : 30.years.ago).to_date,
                               is_business: false, json_data: {})
  uci.individual_tax_id = "000000000"; uci.save!(validate: false)
  UserComplianceInfo.find(uci.id).update!(guardian_id: g.id) if g
  [u.reload, g]
end

def make_account(u, id)
  MerchantAccount.create!(user: u, charge_processor_id: "stripe",
                          charge_processor_merchant_id: id, charge_processor_alive_at: Time.current)
end

# ---- Stripe stubs: an in-memory account -> [person ids] map ------------------
CALLS = []; LIST = {}; DELETE_REFUSE = {}; PERSON_SEQ = { n: 0 }
Stripe::Account.singleton_class.define_method(:list_persons) do |acct_id, params = {}, **kw|
  CALLS << [:list_persons, acct_id]
  Stripe::StripeObject.construct_from(object: "list", has_more: false,
                                      data: (LIST[acct_id] || []).map { |id| Stripe::StripeObject.construct_from(id:, relationship: { legal_guardian: true }) })
end
Stripe::Account.singleton_class.define_method(:retrieve_person) do |acct_id, person_id|
  CALLS << [:retrieve_person, acct_id, person_id]
  raise RETRIEVE_RAISE[person_id] if defined?(RETRIEVE_RAISE) && RETRIEVE_RAISE[person_id]
  raise Stripe::InvalidRequestError.new("No such person: #{person_id}", nil, code: "resource_missing") unless (LIST[acct_id] || []).include?(person_id)
  Stripe::StripeObject.construct_from(id: person_id, relationship: { legal_guardian: true })
end
Stripe::Account.singleton_class.define_method(:create_person) do |acct_id, attrs = {}, **kw|
  PERSON_SEQ[:n] += 1
  pid = "person_#{TAG}_#{RUN}_created#{PERSON_SEQ[:n]}"
  CALLS << [:create_person, acct_id, pid]
  (LIST[acct_id] ||= []) << pid
  Stripe::StripeObject.construct_from(id: pid, relationship: { legal_guardian: true })
end
Stripe::Account.singleton_class.define_method(:update_person) do |acct_id, person_id, attrs = {}, **kw|
  CALLS << [:update_person, acct_id, person_id]
  Stripe::StripeObject.construct_from(id: person_id, relationship: { legal_guardian: true })
end
Stripe::Account.singleton_class.define_method(:delete_person) do |a, p|
  CALLS << [:delete_person, a, p]
  raise DELETE_REFUSE[p] if DELETE_REFUSE[p]
  (LIST[a] || []).delete(p)
  Stripe::StripeObject.construct_from(id: p, deleted: true)
end
RETRIEVE_RAISE = {}
ENQUEUED = []; ENQUEUE_RAISE = { on: nil, n: 0 }
DeleteGuardianStripePersonJob.singleton_class.define_method(:perform_async) do |*a|
  ENQUEUE_RAISE[:n] += 1
  raise Redis::CannotConnectError, "QA forced Redis down on perform_async" if ENQUEUE_RAISE[:on] && ENQUEUE_RAISE[:n] >= ENQUEUE_RAISE[:on]
  ENQUEUED << a; "jid"
end
NOTIFIED = []
ErrorNotifier.singleton_class.define_method(:notify) { |m, *| NOTIFIED << m.to_s[0, 130]; nil }

def notes_for(u)
  Comment.where(commentable_type: "User", commentable_id: u.id).order(:id).map(&:content)
end

def acct(id) = Stripe::StripeObject.construct_from(id: id)
PASS = GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")

puts "\n===== ARM A: reconcile now runs on the UPDATE branch too ====="
uA, gA = seed("armA")
acctA = "acct_#{TAG}_#{RUN}_a"; make_account(uA, acctA)
recorded = "person_#{TAG}_#{RUN}_a_recorded"
orph1 = "person_#{TAG}_#{RUN}_a_orphan1"
orph2 = "person_#{TAG}_#{RUN}_a_orphan2"
LIST[acctA] = [recorded, orph1, orph2]
gA.update_columns(stripe_person_id: recorded)
CALLS.clear
resA = M.sync(uA.reload, acct(acctA), passphrase: PASS)
mark "ARM_A_branch_taken", CALLS.map(&:first).inspect
mark "ARM_A_synced_person", resA&.id.inspect
mark "ARM_A_persons_at_stripe_after", LIST[acctA].inspect
mark "ARM_A_orphans_deleted", CALLS.filter_map { |c| c[2] if c[0] == :delete_person }.inspect
mark "ARM_A_recorded_person_survives", LIST[acctA].include?(recorded)
# PRE-FIX: reconcile sat inside the `else` (create) branch only, so an update reconciled nothing.
mark "ARM_A_PREFIX_orphans_left_at_stripe", [orph1, orph2].inspect
raise "ABORT arm A took the create branch" unless CALLS.any? { |c| c[0] == :update_person }
raise "ABORT arm A did not clear both orphans" unless LIST[acctA] == [recorded]

puts "\n===== ARM B: one refused orphan delete no longer abandons the rest ====="
uB, gB = seed("armB")
acctB = "acct_#{TAG}_#{RUN}_b"; make_account(uB, acctB)
recB = "person_#{TAG}_#{RUN}_b_recorded"
o1 = "person_#{TAG}_#{RUN}_b_orphan1"
o2 = "person_#{TAG}_#{RUN}_b_orphan2"
o3 = "person_#{TAG}_#{RUN}_b_orphan3"
LIST[acctB] = [recB, o1, o2, o3]
gB.update_columns(stripe_person_id: recB)
DELETE_REFUSE[o1] = Stripe::InvalidRequestError.new("QA forced refusal on #{o1}", nil, code: "parameter_invalid_empty")
CALLS.clear; NOTIFIED.clear
M.sync(uB.reload, acct(acctB), passphrase: PASS)
attempted = CALLS.filter_map { |c| c[2] if c[0] == :delete_person }
mark "ARM_B_delete_attempts", attempted.inspect
mark "ARM_B_persons_at_stripe_after", LIST[acctB].inspect
mark "ARM_B_notified", NOTIFIED.grep(/QA forced refusal/).size
mark "ARM_B_sync_raised", false
# PRE-FIX: only a method-level rescue outside the enumeration, so the first raise aborted the loop.
mark "ARM_B_PREFIX_attempts", [o1].inspect
mark "ARM_B_PREFIX_left_at_stripe", [recB, o1, o2, o3].inspect
raise "ABORT arm B did not attempt all three orphans" unless attempted.sort == [o1, o2, o3].sort
raise "ABORT arm B left a deletable orphan" unless LIST[acctB].sort == [recB, o1].sort
DELETE_REFUSE.clear

puts "\n===== ARM C: erasure for a seller with NO guardian no longer takes the sync lock ====="
uC, = seed("armC", minor: false, guardian: false)
acctC = "acct_#{TAG}_#{RUN}_c"; make_account(uC, acctC)
LIST[acctC] = []
LOCKS = []
REAL_LOCK = M.method(:with_account_sync_lock)
M.singleton_class.define_method(:with_account_sync_lock) do |a, d, &blk|
  LOCKS << a
  REAL_LOCK.call(a, d, &blk)
end
CALLS.clear; ENQUEUED.clear; LOCKS.clear
resC = S.new(uC.reload, performed_by: ADMIN).perform!
mark "ARM_C_guardians", uC.guardians.count
mark "ARM_C_success", resC[:success]
mark "ARM_C_locks_taken", LOCKS.inspect
mark "ARM_C_stripe_calls", CALLS.inspect
mark "ARM_C_notes", notes_for(uC).grep(/GDPR erasure incomplete/).size
# PRE-FIX: the union ran unconditionally, so this seller's account was resolved and locked.
mark "ARM_C_PREFIX_locks_taken", [acctC].inspect
raise "ABORT arm C took a lock for a guardian-less seller" unless LOCKS.empty?

puts "\n===== ARM D: an UNRESOLVABLE Stripe merchant row alongside a good one ====="
uD, gD = seed("armD")
acctD_good = "acct_#{TAG}_#{RUN}_d_good"
make_account(uD, acctD_good)
# A real reachable state, not a forced one: the presence validation on
# charge_processor_merchant_id is `if: charge_processor_alive?`, so a row that is not alive is
# legally allowed to carry no merchant id -- and resolve_guardian_stripe_account_ids does NOT
# filter on alive, it just filter_maps the id away.
unresolvable_row = MerchantAccount.create!(user: uD, charge_processor_id: "stripe",
                                           charge_processor_merchant_id: nil)
# The Person lives on the account whose id we cannot resolve, so Stripe answers "no such person"
# for the good account -- which delete_person_by_id reports as SUCCESS.
hidden = "person_#{TAG}_#{RUN}_d_on_unresolvable"
gD.update_columns(stripe_person_id: hidden)
LIST[acctD_good] = []
CALLS.clear; ENQUEUED.clear; NOTIFIED.clear
svcD = S.new(uD.reload, performed_by: ADMIN)
resD = svcD.perform!
mark "ARM_D_unresolvable_row", { id: unresolvable_row.id, merchant_id: unresolvable_row.charge_processor_merchant_id.inspect, alive: unresolvable_row.charge_processor_alive?, in_stripe_scope: uD.merchant_accounts.reload.stripe.include?(unresolvable_row) }.inspect
mark "ARM_D_resolved_accounts", svcD.send(:resolve_guardian_stripe_account_ids).inspect
mark "ARM_D_resolved_set_empty", svcD.send(:resolve_guardian_stripe_account_ids).empty?
mark "ARM_D_unresolvable_rows_predicate", svcD.send(:unresolvable_stripe_merchant_rows?)
mark "ARM_D_success", resD[:success]
mark "ARM_D_error", resD[:error].to_s[0, 130].inspect
mark "ARM_D_unreachable_person_ids", svcD.instance_variable_get(:@unreachable_guardian_person_ids).inspect
mark "ARM_D_note", notes_for(uD).grep(/GDPR erasure incomplete/).first.to_s[0, 240].inspect
mark "ARM_D_row_anonymized_name", gD.reload.first_name.inspect
mark "ARM_D_person_id_retained", gD.reload.stripe_person_id.inspect
# PRE-FIX: keyed on `stripe_account_ids.empty?`. The set is NON-empty here (the good account
# resolved), so no unreachable claim was made and the delete against the good account returned
# "No such person" == success.
mark "ARM_D_PREFIX_gate_fires", svcD.send(:resolve_guardian_stripe_account_ids).empty?
mark "ARM_D_PREFIX_success", true
raise "ABORT arm D reported the erasure complete" if resD[:success]
raise "ABORT arm D made no unreachable claim" unless svcD.instance_variable_get(:@unreachable_guardian_person_ids) == [hidden]
raise "ABORT arm D's pre-fix gate would also have fired" if svcD.send(:resolve_guardian_stripe_account_ids).empty?

puts "\n===== ARM E: the incomplete-erasure note is written BEFORE the enqueue ====="
uE, gE = seed("armE")
acctE = "acct_#{TAG}_#{RUN}_e"; make_account(uE, acctE)
pE = "person_#{TAG}_#{RUN}_e"
gE.update_columns(stripe_person_id: pE)
LIST[acctE] = [pE]
svcE = S.new(uE.reload, performed_by: ADMIN)
# Fail AFTER the local commit but before the deletion step, so the generic remediation fires --
# and force perform_async to raise (Redis down), the case the reorder exists for.
svcE.singleton_class.define_method(:remove_profile_assets!) { raise "QA forced failure after the local commit" }
ENQUEUE_RAISE[:on] = 1; ENQUEUE_RAISE[:n] = 0
CALLS.clear; ENQUEUED.clear; NOTIFIED.clear
resE = svcE.perform!
mark "ARM_E_success", resE[:success]
mark "ARM_E_error", resE[:error].to_s[0, 110].inspect
mark "ARM_E_enqueues_landed", ENQUEUED.inspect
mark "ARM_E_enqueue_raised", NOTIFIED.grep(/QA forced Redis down/).size
mark "ARM_E_note_written", notes_for(uE).grep(/GDPR erasure incomplete/).first.to_s[0, 220].inspect
mark "ARM_E_note_names_person", notes_for(uE).any? { |n| n.include?(pE) }
mark "ARM_E_person_id_retained", gE.reload.stripe_person_id.inspect
mark "ARM_E_row_anonymized_name", gE.reload.first_name.inspect
# PRE-FIX: the enqueue loop ran first, so the very first perform_async raised, jumped to the
# method's own rescue, and record_incomplete_erasure_note! was never reached.
mark "ARM_E_PREFIX_note_written", false
raise "ABORT arm E wrote no durable note" unless notes_for(uE).any? { |n| n.include?("GDPR erasure incomplete") && n.include?(pE) }
raise "ABORT arm E's forced Redis failure did not fire" if NOTIFIED.grep(/QA forced Redis down/).empty?
ENQUEUE_RAISE[:on] = nil

puts "\n===== ARM F: a NON-resource_missing refusal on the recorded id now re-raises ====="
uF, gF = seed("armF")
acctF = "acct_#{TAG}_#{RUN}_f"; make_account(uF, acctF)
pF = "person_#{TAG}_#{RUN}_f"
gF.update_columns(stripe_person_id: pF)
LIST[acctF] = [pF]
# A refusal whose MESSAGE contains "No such person" but whose code is NOT resource_missing.
RETRIEVE_RAISE[pF] = Stripe::InvalidRequestError.new("Permission denied. No such person: #{pF}", nil, code: "account_invalid")
CALLS.clear
raised = nil
begin
  M.sync(uF.reload, acct(acctF), passphrase: PASS)
rescue => e
  raised = "#{e.class}: #{e.message[0, 70]}"
end
mark "ARM_F_raised", raised.inspect
mark "ARM_F_calls", CALLS.map(&:first).inspect
mark "ARM_F_created_a_duplicate", CALLS.any? { |c| c[0] == :create_person }
mark "ARM_F_persons_at_stripe", LIST[acctF].inspect
# PRE-FIX: `raise unless e.message.include?("No such person")` alone -- the message matched, so the
# refusal was swallowed, the scan found nothing (limit 1 list is stubbed empty for a fresh acct in
# the pre-fix reading) and a DUPLICATE Person was created.
mark "ARM_F_PREFIX_swallowed", true
raise "ABORT arm F swallowed a non-resource_missing refusal" if raised.nil?
raise "ABORT arm F created a duplicate" if CALLS.any? { |c| c[0] == :create_person }
RETRIEVE_RAISE.clear

puts "\n===== ARM G: the job's payout breadcrumb is written BEFORE the notify ====="
uG, _ = seed("armG")
pG = "person_#{TAG}_#{RUN}_g"
acctG = "acct_#{TAG}_#{RUN}_g"
blk = DeleteGuardianStripePersonJob.sidekiq_retries_exhausted_block
REAL_NOTIFY = ErrorNotifier.method(:notify)
ErrorNotifier.singleton_class.define_method(:notify) { |m, *| NOTIFIED << m.to_s[0, 130]; raise "QA forced Sentry transport down" }
NOTIFIED.clear
g_raised = nil
begin
  blk.call({ "args" => [pG, acctG, uG.id] }, RuntimeError.new("underlying"))
rescue => e
  g_raised = "#{e.class}: #{e.message[0, 60]}"
end
ErrorNotifier.singleton_class.define_method(:notify) { |m, *| NOTIFIED << m.to_s[0, 130]; nil }
mark "ARM_G_notify_raised", g_raised.inspect
mark "ARM_G_breadcrumb_written", notes_for(uG).grep(/exhausted Sidekiq retries/).first.to_s[0, 200].inspect
mark "ARM_G_breadcrumb_names_person", notes_for(uG).any? { |n| n.include?(pG) }
# PRE-FIX: notify ran first, so its raise skipped add_payout_note entirely.
mark "ARM_G_PREFIX_breadcrumb_written", false
raise "ABORT arm G wrote no breadcrumb" unless notes_for(uG).any? { |n| n.include?(pG) }

puts "\n===== end state ====="
mark "REDIS_keys_after", $redis.keys("stripe_guardian_sync*").inspect
mark "SEEDED_USERS", [uA, uB, uC, uD, uE, uF, uG].map(&:id).inspect
mark "STRIPE_OBJECTS_CREATED", "0 (Stripe::Account fully stubbed on its singleton)"
mark "RUN_OK", true
