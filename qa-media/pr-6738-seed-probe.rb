# frozen_string_literal: true

def mark(k, v) = puts("MARK #{k}=#{v}")

u = User.find_by(email: "seller@gumroad.com")

# --- Flags for the UPI Autopay recurring registration lane ---
%i[
  buyer_currency_charging
  buyer_local_currency
  buyer_currency_subscriptions
  stripe_payment_element_checkout
  stripe_payment_element_client_confirm
  checkout_local_method_upi
  checkout_local_method_upi_recurring
].each { |f| Feature.activate_user(f, u) }
mark "flags_after", %i[buyer_currency_charging buyer_local_currency buyer_currency_subscriptions
                       stripe_payment_element_checkout stripe_payment_element_client_confirm
                       checkout_local_method_upi checkout_local_method_upi_recurring]
                    .index_with { |f| Feature.active?(f, u) }.inspect

# --- GeoIP candidates for an Indian buyer ---
%w[49.36.0.1 1.6.0.1 103.21.124.1 122.176.0.1].each do |ip|
  c = GeoIp.lookup(ip)
  mark "geoip_#{ip}", { name: c&.country_name, a2: (Compliance::Countries.find_by_name(c&.country_name)&.alpha2) }.inspect
end

# --- Seed the INR membership (dup of the seeded tiered membership) ---
src = Link.find(2)
existing = Link.find_by(unique_permalink: "qaupi")
if existing
  l = existing
  mark "reused_link", l.id
else
  l = src.dup
  l.unique_permalink = "qaupi"
  l.custom_permalink = nil
  l.name = "QA6738 INR Autopay membership"
  l.price_currency_type = "inr"
  l.price_cents = 49_900
  l.customizable_price = false
  l.free_trial_enabled = false
  l.is_physical = false
  l.is_in_preorder_state = false
  l.save!(validate: false)
  mark "created_link", l.id
end
l.update_columns(price_currency_type: "inr", price_cents: 49_900, subscription_duration: "monthly")

# base price row
if l.prices.alive.where(variant_id: nil).empty?
  l.prices.create!(price_cents: 49_900, currency: "inr", recurrence: "monthly")
end
l.prices.alive.where(variant_id: nil).each { |p| p.update_columns(price_cents: 49_900, currency: "inr", recurrence: "monthly") }

# tier
vc = l.variant_categories.alive.first || l.variant_categories.create!(title: "Tier")
tier = vc.alive_variants.first
if tier.nil?
  tier = vc.variants.create!(name: "Autopay tier")
end
if tier.prices.alive.empty?
  tier.prices.create!(link: l, price_cents: 49_900, currency: "inr", recurrence: "monthly")
end
tier.prices.alive.each { |p| p.update_columns(price_cents: 49_900, currency: "inr", recurrence: "monthly", link_id: l.id) }

l.reload
mark "link_final", { id: l.id, slug: l.unique_permalink, cur: l.price_currency_type, price: l.price_cents,
                     dur: l.subscription_duration, tiered: l.is_tiered_membership?, alive: l.alive?,
                     published: l.purchase_disabled_at.nil?, native: l.native_type,
                     free_trial: l.free_trial_enabled, pwyw: l.customizable_price?,
                     installment: l.installment_plan.present? }.inspect
mark "link_prices", l.prices.alive.map { |p| [p.id, p.price_cents, p.currency, p.recurrence, p.variant_id] }.inspect
mark "tier", { id: tier.id, name: tier.name, prices: tier.prices.alive.map { |p| [p.id, p.price_cents, p.currency, p.recurrence] } }.inspect
mark "link_url", l.long_url

# --- Warm the INR FX rate cache (display side) ---
ns = Object.new.extend(CurrencyHelper).currency_namespace
ns.set("INR", 87.5) if ns.get("INR").blank?
mark "fx_inr", ns.get("INR").inspect

# --- Resolver dry runs: the arms the PR adds ---
def resolve(**kw)
  r = Checkout::PaymentMethodResolver.new(**kw).resolve
  { eligible: r.client_confirm_eligible, reason: r.fallback_reason, types: r.payment_method_types,
    policy: r.eligible_payment_method_types }
end

base = { sellers: [u], recurring: true, buyer_country: "IN", cart_product_currency: "inr" }
mark "R_upi_registration", resolve(**base, recurring_upi_registration: true).inspect
mark "R_recurring_no_upi", resolve(**base, recurring_upi_registration: false).inspect
mark "R_onetime_inr", resolve(sellers: [u], recurring: false, buyer_country: "IN", cart_product_currency: "inr").inspect
mark "R_upi_reg_nonIN", resolve(**base.merge(buyer_country: "US"), recurring_upi_registration: true).inspect
mark "R_upi_reg_usd", resolve(**base.merge(cart_product_currency: nil), recurring_upi_registration: true).inspect

Feature.deactivate_user(:checkout_local_method_upi_recurring, u)
mark "R_upi_reg_flag_off", resolve(**base, recurring_upi_registration: true).inspect
Feature.activate_user(:checkout_local_method_upi_recurring, u)
mark "flag_restored", Feature.active?(:checkout_local_method_upi_recurring, u).inspect

mark "DONE", 1
