M = "MARK6477"
def m(k, v) = puts("#{M} #{k}=#{v}")

m "revision", (ENV["REVISION"] || ENV["GIT_SHA"] || `cat /app/REVISION 2>/dev/null`.strip)

# 1. The comment-trim head must not have moved the constant.
m "MAX_QUOTED_CHARGES", Checkout::BuyerCurrencyQuote::MAX_QUOTED_CHARGES
m "quote_methods_present", [
  Checkout::BuyerCurrencyQuote.singleton_class.private_instance_methods.include?(:display_rate_for),
  Checkout::BuyerCurrencyQuote.singleton_class.private_instance_methods.include?(:signed_token),
  Checkout::BuyerCurrencyQuote.respond_to?(:create),
].inspect

# 2. The PR's own line: seller: threaded into supported_merchant_account?
params = Checkout::BuyerCurrencyEligibility.method(:supported_merchant_account?).parameters
m "supported_merchant_account_params", params.inspect

seller = User.find_by(email: "seller@gumroad.com")
m "seller_id", seller&.id
ma = seller&.merchant_accounts&.alive&.detect { |a| a.charge_processor_id == "stripe" }
m "seller_ma", ma&.id
if ma
  m "ma_managed_by_gumroad", ma.is_managed_by_gumroad?
  m "ma_stripe_connect", ma.is_a_stripe_connect_account?
  branch = begin
    Checkout::BuyerCurrencyEligibility.supported_merchant_account?(ma, seller: seller)
  rescue => e
    "ERR:#{e.class}:#{e.message[0, 80]}"
  end
  prefix = begin
    Checkout::BuyerCurrencyEligibility.supported_merchant_account?(ma)
  rescue => e
    "ERR:#{e.class}:#{e.message[0, 80]}"
  end
  m "gate_branch_with_seller", branch
  m "gate_prefix_without_seller", prefix
end

# 3. Durable preview state the body claims: warmed FX cache.
begin
  ns = Object.new.extend(CurrencyHelper).currency_namespace
  m "fx_CAD", ns.get("CAD").inspect
rescue => e
  m "fx_err", "#{e.class}:#{e.message[0, 80]}"
end

# 4. Flag states (body claims restored to pre-run values).
%i[buyer_currency_destination_charges buyer_currency_subscriptions].each do |f|
  m "flag_#{f}_global", (Feature.active?(f) rescue "ERR")
  m "flag_#{f}_seller", (seller && (Feature.active?(f, seller) rescue "ERR"))
end

# 5. The re-arming head renumbered migrations. Check REAL DDL, not schema_migrations.
conn = ActiveRecord::Base.connection
%w[later_charge_presentments guardians].each do |t|
  m "table_#{t}_exists", conn.table_exists?(t)
end
m "uci_has_guardian_id", conn.columns(UserComplianceInfo.table_name).map(&:name).include?("guardian_id")
begin
  m "lcp_has_canonical_price_cents",
    (conn.table_exists?("later_charge_presentments") ?
      conn.columns("later_charge_presentments").map(&:name).include?("canonical_price_cents") : "n/a")
rescue => e
  m "lcp_col_err", "#{e.class}"
end
recorded = conn.select_values("SELECT version FROM schema_migrations WHERE version LIKE '202612060000%' ORDER BY version")
m "recorded_2026120600001x", recorded.inspect
m "pending_migration", (ActiveRecord::Migration.check_all_pending! ; "none") rescue "PENDING:#{$!.class}"
m "done", 1
