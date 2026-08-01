# frozen_string_literal: true

# Re-verification probe for PR #6738 at the main-merge head e673d3c6a.
# The redeploy reseeded the preview DB, so this re-seeds the INR membership + one-time
# control, then drives Checkout::PaymentMethodResolver per-arm on the live pod.
def mark(k, v) = puts("MARK #{k}=#{v}")

seller = User.find_by(email: "seller@gumroad.com")
mark "seller", seller.id

FLAGS = %i[
  buyer_currency_charging buyer_local_currency buyer_currency_subscriptions
  stripe_payment_element_checkout stripe_payment_element_client_confirm
  checkout_local_method_upi checkout_local_method_upi_recurring
].freeze
FLAGS.each { Feature.activate_user(_1, seller) }
mark "flags", FLAGS.index_with { Feature.active?(_1, seller) }.inspect

ns = Object.new.extend(CurrencyHelper).currency_namespace
mark "inr_rate_before", ns.get("INR").inspect
ns.set("INR", 95.40235) if ns.get("INR").blank?
mark "inr_rate_now", ns.get("INR").inspect

# ---- code presence at the served revision ----
mark "code_chargeable_upi", (defined?(StripeChargeableUpi) ? "yes" : "NO")
mark "code_cc_cols", (CreditCard.column_names.grep(/recurring_payment_method/).sort).inspect
mark "code_prepare_upi", Order::PreparePaymentIntentService.private_instance_methods.grep(/upi/).sort.inspect
mark "code_upi_max", Checkout::PaymentMethodResolver::UPI_RECURRING_MAX_INR_CENTS
mark "code_upi_feature", Checkout::PaymentMethodResolver::UPI_RECURRING_LAUNCH_FEATURE.inspect

# ---- seed the INR membership (this PR's shape) ----
mem = Link.find_by(unique_permalink: "qaupi")
if mem.blank?
  src = Link.find(2)
  mem = src.dup
  mem.unique_permalink = "qaupi"
  mem.custom_permalink = nil
  mem.customizable_price = false
  mem.name = "QA6738 INR membership"
  mem.save!(validate: false)
  src.variant_categories.alive.each do |vc|
    nvc = vc.dup
    nvc.link_id = mem.id
    nvc.save!(validate: false)
    vc.alive_variants.each do |v|
      nv = v.dup
      nv.variant_category_id = nvc.id
      nv.save!(validate: false)
      v.prices.alive.each do |p|
        np = p.dup
        np.variant_id = nv.id
        np.link_id = mem.id
        np.save!(validate: false)
      end
    end
  end
  src.prices.alive.each do |p|
    np = p.dup
    np.link_id = mem.id
    np.save!(validate: false)
  end
end
mem.update_columns(price_currency_type: "inr", price_cents: 49_900, subscription_duration: "monthly")
mem.prices.alive.each { _1.update_columns(price_cents: 49_900, currency: "inr", recurrence: "monthly") }
mem.variant_categories.alive.each do |vc|
  vc.alive_variants.each do |v|
    v.prices.alive.each { _1.update_columns(price_cents: 49_900, currency: "inr", recurrence: "monthly", link_id: mem.id) }
  end
end
mem.reload
mark "membership", { id: mem.id, perma: mem.unique_permalink, cur: mem.price_currency_type,
                     cents: mem.price_cents, dur: mem.subscription_duration,
                     tiered: mem.is_tiered_membership?, native: mem.native_type }.inspect

# ---- seed the one-time control (pre-existing UPI lane) ----
ctl = Link.find_by(unique_permalink: "qaupione")
if ctl.blank?
  ctl = mem.dup
  ctl.unique_permalink = "qaupione"
  ctl.custom_permalink = nil
  ctl.name = "QA6738 INR one-time control"
  ctl.subscription_duration = nil
  ctl.save!(validate: false)
  mem.prices.alive.each do |p|
    np = p.dup
    np.link_id = ctl.id
    np.variant_id = nil
    np.recurrence = nil
    np.save!(validate: false)
  end
end
ctl.update_columns(price_currency_type: "inr", price_cents: 49_900, subscription_duration: nil)
ctl.prices.alive.each { _1.update_columns(price_cents: 49_900, currency: "inr", recurrence: nil) }
ctl.reload
mark "control", { id: ctl.id, perma: ctl.unique_permalink, cur: ctl.price_currency_type,
                  dur: ctl.subscription_duration.inspect }.inspect

# ---- resolver arms ----
def arm(label, **kwargs)
  r = Checkout::PaymentMethodResolver.new(**kwargs).resolve
  mark "arm", "#{label} | eligible=#{r.client_confirm_eligible.inspect} " \
              "fallback=#{r.fallback_reason.inspect} types=#{r.payment_method_types.inspect}"
rescue StandardError => e
  mark "arm", "#{label} | ERR #{e.class}: #{e.message[0, 160]}"
end

S = [seller].freeze

arm "1-membership-flag-on(THIS PR)", sellers: S, recurring: true, buyer_country: "IN",
                                     cart_product_currency: "inr", recurring_upi_registration: true
arm "2-membership-flag-arg-false(PRE-PR)", sellers: S, recurring: true, buyer_country: "IN",
                                           cart_product_currency: "inr", recurring_upi_registration: false
arm "3-one-time-control", sellers: S, recurring: false, buyer_country: "IN",
                          cart_product_currency: "inr"
arm "4-membership-buyer-not-india", sellers: S, recurring: true, buyer_country: "US",
                                    cart_product_currency: "inr", recurring_upi_registration: true
arm "5-membership-no-forced-currency", sellers: S, recurring: true, buyer_country: "IN",
                                       cart_product_currency: nil, recurring_upi_registration: true

Feature.deactivate_user(:checkout_local_method_upi_recurring, seller)
arm "6-membership-flipper-OFF", sellers: S, recurring: true, buyer_country: "IN",
                                cart_product_currency: "inr", recurring_upi_registration: true
Feature.activate_user(:checkout_local_method_upi_recurring, seller)
mark "flag_restored", Feature.active?(:checkout_local_method_upi_recurring, seller)

mark "DONE", 1
