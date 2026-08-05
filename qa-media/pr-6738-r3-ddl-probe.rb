# frozen_string_literal: true

def mark(k, v) = puts("MARK #{k}=#{v}")

# The recon run reported code_cc_cols=[] where the previous head had all five columns.
# The grep was on /recurring_payment_method/, which never matched any real column name --
# confirm against the LIVE DDL rather than schema_migrations, which can record a migration
# whose DDL never ran.
cols = ActiveRecord::Base.connection.columns("credit_cards").map(&:name)
want = %w[
  recurring_authorization_verified_at
  recurring_authorization_currency
  recurring_authorization_max_amount_cents
  stripe_account_id
  processor_payment_method_id
]
mark "ddl_present", want.index_with { cols.include?(_1) }.inspect
mark "ddl_missing", (want - cols).inspect

sm = ActiveRecord::Base.connection.select_values(
  "SELECT version FROM schema_migrations WHERE version LIKE '202612060000%' ORDER BY version"
)
mark "schema_migrations_20261206", sm.inspect

begin
  cc = CreditCard.new
  mark "recurring_upi?", cc.recurring_upi?.inspect
rescue => e
  mark "recurring_upi_RAISES", "#{e.class}: #{e.message[0, 160]}"
end

mark "DONE", 1
