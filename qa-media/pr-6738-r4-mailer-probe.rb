# frozen_string_literal: true

ActiveRecord::Base.logger = nil
Rails.logger.level = Logger::FATAL
require "base64"

out = []
def m(out, s) = out << s

sub = Subscription.find(3)
link = sub.link
seller = link.user
m out, "SUB=#{sub.id} link=#{link.name.inspect} seller=#{seller.id} email=#{sub.email.inspect}"

# The mailer reads @subscription.original_purchase.seller, so the subscription needs its
# original purchase row. Seed one if a previous run did not.
op = sub.original_purchase rescue nil
if op.nil?
  price = link.prices.alive.first || link.prices.first
  m out, "PRICE=#{price&.id} cents=#{price&.price_cents}"
  p = Purchase.new(link: link, seller: seller, purchaser: sub.user,
                   email: "qa6738buyer@gumroad.com", full_name: "QA6738 Buyer",
                   price_cents: price&.price_cents || 500,
                   displayed_price_cents: price&.price_cents || 500,
                   subscription: sub, credit_card_id: sub.credit_card_id,
                   purchase_state: "successful", is_original_subscription_purchase: true)
  p.save!(validate: false)
  sub.reload
  m out, "SEEDED original_purchase=#{p.id}"
end
op = sub.original_purchase
m out, "ORIG_PURCHASE=#{op&.id} seller=#{op&.seller&.id}"

UPI = Checkout::PaymentMethodResolver::UPI_PAYMENT_METHOD_TYPE
m out, "UPI_PAYMENT_METHOD_TYPE=#{UPI.inspect}"

renders = {}
def render_pair(sub, tag, renders, out)
  %w[subscription_card_declined subscription_card_declined_warning].each do |meth|
    mail = CustomerLowPriorityMailer.public_send(meth, sub.id)
    body = mail.body.to_s
    key = "#{meth}-#{tag}"
    renders[key] = body
    out << "RENDER #{key} subject=#{mail.subject.inspect} upi_copy=#{body.include?('saved UPI payment method')} card_copy=#{body.include?('attempted to charge your card')} bytes=#{body.bytesize}"
  end
end

cc = sub.credit_card_to_charge
m out, "TARGET_CC=#{cc&.id}"

cc.update_columns(payment_method_type: "card")
sub.reload
m out, "STATE control type=#{sub.credit_card_to_charge.payment_method_type.inspect} recurring_upi=#{sub.credit_card_to_charge.recurring_upi?}"
render_pair(sub, "card-control", renders, out)

cc.update_columns(payment_method_type: UPI)
sub.reload
m out, "STATE upi type=#{sub.credit_card_to_charge.payment_method_type.inspect} recurring_upi=#{sub.credit_card_to_charge.recurring_upi?}"
render_pair(sub, "upi", renders, out)

cc.update_columns(payment_method_type: "card")
m out, "STATE restored type=#{cc.reload.payment_method_type.inspect}"

d_card = renders["subscription_card_declined-card-control"].to_s
d_upi  = renders["subscription_card_declined-upi"].to_s
w_card = renders["subscription_card_declined_warning-card-control"].to_s
w_upi  = renders["subscription_card_declined_warning-upi"].to_s
m out, "ASSERT declined card!=upi -> #{d_card != d_upi}"
m out, "ASSERT warning  card!=upi -> #{w_card != w_upi}"
m out, "ASSERT upi_declined '5 days'   -> #{d_upi.include?('within 5 days')}"
m out, "ASSERT upi_warning  '48 hours' -> #{w_upi.include?('within 48 hours')}"
m out, "ASSERT card control 'card was declined' -> #{d_card.include?('Your card was declined')}"
m out, "ASSERT upi 'update your payment method' -> #{d_upi.include?('update your payment method')}"
m out, "ASSERT card control has NO upi copy -> #{!d_card.include?('saved UPI payment method')}"

renders.each { |k, v| m out, "B64 #{k} #{Base64.strict_encode64(v)}" }
puts "\n===MARKS===\n" + out.join("\n")
