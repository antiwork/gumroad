# frozen_string_literal: true

# QA 14b — the two claims the body makes that a re-seeded preview DB could have invalidated.
def m(k, v) = puts("MARK #{k}=#{v}")

g = Guardian.find(1)
m "g1_id", g.id
m "g1_stripe_person_id", g.stripe_person_id
m "g1_first_name", g.first_name.inspect
m "g1_last_name", g.last_name.inspect
m "g1_email", g.email.inspect
m "g1_dob", g.date_of_birth.inspect
m "g1_deleted_at", g.deleted_at.inspect
m "guardian_has_deleted_at_column", Guardian.column_names.include?("deleted_at")
u = User.find_by(id: g.user_id)
m "g1_user", u ? "users##{u.id} email=#{u.email.inspect} deleted_at=#{u.deleted_at.inspect}" : "user #{g.user_id} MISSING"

# Does the Stripe Person the erasure deliberately retained as its retry handle still stand?
acct = "acct_1TzBvSS7TA4UpgOG"
begin
  persons = Stripe::Account.list_persons(acct, { limit: 100 })
  rows = persons.data.map { |p| [p.id, (p.relationship.respond_to?(:legal_guardian) ? p.relationship.legal_guardian : nil)] }
  m "stripe_account_reachable", true
  m "stripe_persons_count", rows.length
  m "stripe_persons", rows.inspect
  m "retained_person_still_at_stripe", rows.map(&:first).include?(g.stripe_person_id)
rescue => e
  m "stripe_account_reachable", "#{e.class}: #{e.message[0, 120]}"
end

# The DDL half of the re-seed, spelled out per table (schema_migrations is not authoritative).
conn = ActiveRecord::Base.connection
m "lcp_table_exists", conn.table_exists?("later_charge_presentments")
begin
  m "LaterChargePresentment_count", LaterChargePresentment.count
rescue => e
  m "LaterChargePresentment_count", "#{e.class}"
end
m "lcp_has_canonical_price_cents", (conn.table_exists?("later_charge_presentments") ? conn.columns("later_charge_presentments").map(&:name).include?("canonical_price_cents") : "n/a")
sace = conn.indexes("sent_abandoned_cart_emails").filter_map { |i| i.name if i.unique }
m "sent_abandoned_cart_emails_unique_indexes", sace.inspect

m "PROBE_OK", true
