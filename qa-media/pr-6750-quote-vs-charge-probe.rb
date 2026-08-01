# frozen_string_literal: true

MARK = "MARK6750"
def m(s) = puts("#{MARK} #{s}")

s = User.find_by(email: "seller@gumroad.com")
a = Link.find(1)
b = s.links.alive.find_by(name: "QA6750 Widget B")
oc = s.offer_codes.alive.find_by(code: "QA6750FIXED")
m "fixtures a=#{a.unique_permalink}/#{a.price_cents} b=#{b.unique_permalink}/#{b.price_cents} oc=#{oc.code}/#{oc.amount_cents}c is_cents=#{oc.is_cents?}"

products = {
  a.unique_permalink => { permalink: a.unique_permalink, quantity: 1 },
  b.unique_permalink => { permalink: b.unique_permalink, quantity: 1 },
}
resp = OfferCodeDiscountComputingService.new(oc.code, products).process
m "QUOTE products_data=#{resp[:products_data].inspect}"
m "QUOTE keys=#{resp.keys.inspect}"
m "QUOTE ineligibility=#{resp.except(:products_data).inspect}"

# The quote's cart-level total: subtotal 2000 minus the sum of the emitted discounts.
disc = resp[:products_data].values.sum { |v| v[:discount][:cents].to_i }
m "QUOTE subtotal=2000 discount_sum=#{disc} quoted_total=#{2000 - disc}"

# CHARGE layer over the SAME two lines. offer_amount_off re-derives from
# offer_code.amount_cents per line; it never reads products_data.
charged = [a, b].map do |l|
  p = Purchase.new(link: l, seller: s, price_cents: 1000, displayed_price_cents: 1000,
                   offer_code: oc, quantity: 1)
  off = p.send(:offer_amount_off, 1000)
  m "CHARGE #{l.unique_permalink} offer_amount_off=#{off}"
  off
end
m "CHARGE discount_sum=#{charged.sum} charged_total=#{2000 - charged.sum}"
m "VERDICT quote_total=#{2000 - disc} charge_total=#{2000 - charged.sum} divergence=#{(2000 - disc) - (2000 - charged.sum)}"

# That divergence is exactly what trips the buyer-facing validator: the browser submits the
# quoted price for the zero-discount line, the charge layer re-prices it lower.
zero_line = resp[:products_data].find { |_, v| v[:discount][:cents].to_i.zero? }&.first
if zero_line
  zl = Link.find_by(unique_permalink: zero_line)
  p = Purchase.new(link: zl, seller: s, offer_code: oc, quantity: 1,
                   displayed_price_cents: 1000, perceived_price_cents: 1000)
  p.send(:set_price_and_rate) rescue nil
  m "SUBMIT line=#{zero_line} quoted_by_cart=1000 price_cents_after_pricing=#{p.price_cents.inspect}"
  p.valid?
  m "SUBMIT error_code=#{p.error_code.inspect}"
  m "SUBMIT buyer_facing_errors=#{p.errors.full_messages.inspect}"
end
m "DONE"
