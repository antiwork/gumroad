# frozen_string_literal: true

def mark(k, v) = puts("MARK #{k}=#{v}")

src = Link.find(1)

l = Link.find_by(unique_permalink: "qaupione")
if l.nil?
  l = src.dup
  l.unique_permalink = "qaupione"
  l.custom_permalink = nil
  l.name = "QA6738 INR one-time (control)"
  l.price_currency_type = "inr"
  l.price_cents = 49_900
  l.customizable_price = false
  l.subscription_duration = nil
  l.save!(validate: false)
  mark "created", l.id
else
  mark "reused", l.id
end
l.update_columns(price_currency_type: "inr", price_cents: 49_900, subscription_duration: nil)
if l.prices.alive.empty?
  l.prices.create!(price_cents: 49_900, currency: "inr", recurrence: nil)
end
l.prices.alive.each { |p| p.update_columns(price_cents: 49_900, currency: "inr", recurrence: nil) }
l.reload
mark "control_link", { id: l.id, slug: l.unique_permalink, cur: l.price_currency_type, price: l.price_cents,
                       dur: l.subscription_duration, pwyw: l.customizable_price?, native: l.native_type,
                       prices: l.prices.alive.map { |p| [p.price_cents, p.currency, p.recurrence] } }.inspect
mark "DONE", 1
