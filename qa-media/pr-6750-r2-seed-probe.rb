# frozen_string_literal: true

M = "MARK6750"
def m(s) = puts("#{M} #{s}")

s = User.find_by(email: "seller@gumroad.com")
m "seller=#{s.id}"

# Product A: reuse the seeded `demo` link as a plain fixed-price $10 product.
a = Link.find(1)
a.customizable_price = false
a.price_cents = 1000
a.name = "QA6750 Widget A"
a.save!(validate: false)
a.prices.alive.each { |p| p.update_columns(price_cents: 1000) }
m "A id=#{a.id} perm=#{a.unique_permalink} price=#{a.price_cents} cust=#{a.customizable_price?} url=#{a.long_url}"

# Product B: created through the normal validated path so the page renders.
b = s.links.alive.find_by(name: "QA6750 Widget B")
if b.nil?
  b = Link.new(user: s, name: "QA6750 Widget B", description: "QA6750 second cart line",
               price_cents: 1000, native_type: "digital", price_currency_type: "usd")
  b.save!
  b.publish!
end
b.customizable_price = false
b.price_cents = 1000
b.save!(validate: false)
b.prices.alive.each { |p| p.update_columns(price_cents: 1000) }
m "B id=#{b.id} perm=#{b.unique_permalink} price=#{b.price_cents} alive=#{b.alive?} url=#{b.long_url}"

# Universal $1 fixed-amount code, uncapped.
oc = s.offer_codes.find_by(code: "QA6750FIXED")
oc&.destroy!
oc = OfferCode.new(user: s, code: "QA6750FIXED", amount_cents: 100, universal: true, currency_type: "usd")
oc.save!
m "OC code=#{oc.code} cents=#{oc.amount_cents} is_cents=#{oc.is_cents?} universal=#{oc.universal?}"

# Second code: same $1 fixed amount but with a MINIMUM QUANTITY of 2. This is the arm the
# re-arming commit's spec is about — a line covered at zero that fails the line-level minimum.
mc = s.offer_codes.find_by(code: "QA6750MINQTY")
mc&.destroy!
mc = OfferCode.new(user: s, code: "QA6750MINQTY", amount_cents: 100, universal: true,
                   currency_type: "usd", minimum_quantity: 2)
mc.save!
m "MC code=#{mc.code} cents=#{mc.amount_cents} min_qty=#{mc.minimum_quantity}"

def qq(code, pairs)
  products = pairs.to_h { |l, q| [l.unique_permalink, { permalink: l.unique_permalink, quantity: q }] }
  OfferCodeDiscountComputingService.new(code, products).process
end

# ARM 1 — this PR's headline shape: 2 lines x 1 unit, universal $1 fixed code.
r1 = qq(oc.code, [[a, 1], [b, 1]])
d1 = r1[:products_data].values.sum { |v| v[:discount][:cents].to_i }
m "ARM1 once-per-cart products_data=#{r1[:products_data].transform_values { |v| v[:discount][:cents] }.inspect}"
m "ARM1 error_code=#{r1[:error_code].inspect} partial=#{r1[:partial_ineligibility_code].inspect}"
m "ARM1 subtotal=2000 discount_sum=#{d1} quoted_total=#{2000 - d1}"

# ARM 2 — the NEW arm the re-arming commit asserts: line A qty 2 (meets min), line B qty 1
# (covered at zero but under the minimum). Must be a PARTIAL application, not a fatal error.
r2 = qq(mc.code, [[a, 2], [b, 1]])
m "ARM2 minqty products_data=#{r2[:products_data].transform_values { |v| v[:discount][:cents] }.inspect}"
m "ARM2 error_code=#{r2[:error_code].inspect} partial=#{r2[:partial_ineligibility_code].inspect}"
m "ARM2 notice=#{OfferCodesController::PARTIAL_APPLICATION_MESSAGES[r2[:partial_ineligibility_code]].inspect}"

# ARM 3 — the pre-#6751 answer on ARM2's inputs would have been a fatal error_code.
m "ARM3 prefix_would_have_been=:unmet_minimum_purchase_quantity (fatal) vs now error_code=#{r2[:error_code].inspect}"

# CHARGE layer over ARM1's two lines — offer_amount_off re-derives per line.
charged = [a, b].map do |l|
  p = Purchase.new(link: l, seller: s, price_cents: 1000, displayed_price_cents: 1000,
                   offer_code: oc, quantity: 1)
  off = p.send(:offer_amount_off, 1000)
  m "CHARGE #{l.unique_permalink} offer_amount_off=#{off}"
  off
end
m "CHARGE discount_sum=#{charged.sum} charged_total=#{2000 - charged.sum}"
m "VERDICT quote_total=#{2000 - d1} charge_total=#{2000 - charged.sum} divergence=#{(2000 - d1) - (2000 - charged.sum)}"
m "DONE"
