# QA 14 — composition probe at the main-merge head dba94798f (#6716 migration renumber merged in).
# The PR's own four app/ files are byte-identical across 5f0668ccc..dba94798f; what the merge
# changed is the guardian migrations' VERSION NUMBERS. So the question is not "does the feature
# still render" (there is no rendered surface) but: does the schema the feature depends on still
# stand on a preview DB that recorded the SUPERSEDED versions, and do both halves of the merged
# tree survive together.
def m(k, v) = puts("MARK #{k}=#{v}")

conn = ActiveRecord::Base.connection
m "served_revision_env", ENV["REVISION"] || ENV["GIT_SHA"] || "(unset)"

# --- 1. DDL read directly. schema_migrations is NOT authoritative on a preview (skill pitfall:
#        a preview DB can record a migration as applied while its DDL was never run).
m "guardians_table_exists", conn.table_exists?("guardians")
m "user_compliance_info_table", UserComplianceInfo.table_name
m "uci_has_guardian_id", conn.columns(UserComplianceInfo.table_name).map(&:name).include?("guardian_id")
gcols = conn.columns("guardians").map(&:name)
%w[user_id stripe_person_id date_of_birth individual_tax_id stripe_tos_accepted country_code].each do |c|
  m "guardians_col_#{c}", gcols.include?(c)
end
uniq = conn.indexes("guardians").select(&:unique).map { |i| [i.name, i.columns] }
m "guardians_unique_indexes", uniq.inspect

# --- 2. The migration-version artifact the body describes, measured rather than asserted.
recorded = conn.select_values("SELECT version FROM schema_migrations WHERE version LIKE '202612%'").sort
m "recorded_202612_versions", recorded.inspect
on_disk = Dir[Rails.root.join("db/migrate/202612*.rb")].map { |f| File.basename(f)[/\A\d+/] }.sort
m "on_disk_202612_versions", on_disk.inspect
m "pending_versions", (on_disk - recorded).inspect
begin
  ActiveRecord::Migration.check_all_pending!
  m "check_all_pending", "clean"
rescue => e
  m "check_all_pending", "#{e.class}"
end
# The renumbered pair is guarded to no-op where the superseded version is recorded — so the
# pending state is cosmetic. Prove the guards' own condition on THIS database.
%w[20261206000015 20261206000016].each { |v| m "superseded_#{v}_recorded", recorded.include?(v) }

# --- 3. Both halves of the merged tree present at the served revision.
m "StripeGuardianManager_defined", defined?(StripeGuardianManager) ? true : false
sgm = StripeGuardianManager.methods(false).sort
m "StripeGuardianManager_singleton_methods", sgm.inspect
m "has_account_scoped_lock", sgm.include?(:with_account_sync_lock)
m "has_paginated_person_scan", (StripeGuardianManager.private_methods(false) + sgm).include?(:each_legal_guardian_person)
m "SyncLockUnavailable_defined", StripeGuardianManager.const_defined?(:SyncLockUnavailable)
m "SYNC_LOCK_TTL", (StripeGuardianManager::SYNC_LOCK_TTL rescue "n/a")
m "erasure_init_params", GdprDataErasureService.instance_method(:initialize).parameters.inspect
m "DeleteGuardianStripePersonJob_retry", DeleteGuardianStripePersonJob.sidekiq_options.slice("retry", "queue").inspect
# main's side of the merge, in the same request path the guardian sync is called from:
m "purchase_has_sanctions_validator", Purchase.private_instance_methods.include?(:validate_sanctioned_location)
m "later_charge_presentments_table", conn.table_exists?("later_charge_presentments")

# --- 4. The durable evidence from the earlier rounds: is it still there at this head?
g = Guardian.where.not(stripe_person_id: nil).order(:id).first
if g
  m "guardian_with_person_id", "guardians##{g.id} person=#{g.stripe_person_id}"
  m "guardian_anonymized_first_name", g.first_name.inspect
  m "guardian_deleted_at_present", !g.deleted_at.nil?
else
  m "guardian_with_person_id", "none"
end
m "guardian_count", Guardian.count
m "guardians_holding_person_id", Guardian.where.not(stripe_person_id: nil).count
m "redis_sync_keys_left_over", $redis.keys("stripe_guardian_sync*").inspect

m "PROBE_OK", true
