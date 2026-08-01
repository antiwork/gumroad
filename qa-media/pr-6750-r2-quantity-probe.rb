# frozen_string_literal: true

M = "MARK6750Q"
def m(s) = puts("#{M} #{s}")

s = User.find_by(email: "seller@gumroad.com")
a = Link.find(1)
b = Link.find(18)
mc = s.offer_codes.alive.find_by(code: "QA6750MINQTY")
oc = s.offer_codes.alive.find_by(code: "QA6750FIXED")

# The cart rendered US$-2 for a $1 code whose service spent ONE use. Locate which layer
# multiplies: the service's emitted per-line cents, or the client's quantity multiplication.
def qq(code, pairs)
  products = pairs.to_h { |l, q| [l.unique_permalink, { permalink: l.unique_permalink, quantity: q }] }
  OfferCodeDiscountComputingService.new(code, products).process
end

r = qq(mc.code, [[a, 2], [b, 1]])
m "SERVICE minqty emits=#{r[:products_data].transform_values { |v| v[:discount] }.inspect}"
m "SERVICE partial=#{r[:partial_ineligibility_code].inspect} error=#{r[:error_code].inspect}"

# The surviving line is qty 2 and carries cents:100. The cart summary multiplies a fixed
# per-line discount by quantity, so a code spent once renders as US$-2.
m "CART would_render=#{r[:products_data].sum { |perm, v| v[:discount][:cents].to_i * (perm == a.unique_permalink ? 2 : 1) }}c for a #{mc.amount_cents}c code"

# CHARGE layer over the same cart: what is actually taken.
[[a, 2], [b, 1]].each do |l, q|
  p = Purchase.new(link: l, seller: s, price_cents: 1000 * q, displayed_price_cents: 1000 * q,
                   offer_code: mc, quantity: q)
  m "CHARGE #{l.unique_permalink} qty=#{q} offer_amount_off=#{p.send(:offer_amount_off, 1000 * q)}"
end

# Control: the SAME shape on the uncapped code with both lines at qty 1 (the headline arm).
r2 = qq(oc.code, [[a, 1], [b, 1]])
m "CONTROL fixed qty1x2 emits=#{r2[:products_data].transform_values { |v| v[:discount][:cents] }.inspect} (renders -1)"
m "DONE"
