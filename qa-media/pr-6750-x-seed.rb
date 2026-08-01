# frozen_string_literal: true

M = "MARK6750X"
def m(s) = puts("#{M} #{s}")

s = User.find_by(email: "seller@gumroad.com")
m "seller=#{s.id}"

# Cart line A: reuse the seeded `demo` link as a plain fixed-price $10 product.
a = Link.find(1)
a.customizable_price = false
a.price_cents = 1000
a.name = "QA6750 Widget A"
a.save!(validate: false)
a.prices.alive.each { |p| p.update_columns(price_cents: 1000) }
m "A id=#{a.id} perm=#{a.unique_permalink} price=#{a.price_cents} cust=#{a.customizable_price?}"

# Cart line B, through the normal validated path so the page renders.
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
m "B id=#{b.id} perm=#{b.unique_permalink} price=#{b.price_cents} alive=#{b.alive?}"

# Cross-sell target: a THIRD product offered as a cross-sell off line A.
x = s.links.alive.find_by(name: "QA6750 Widget X (cross-sell)")
if x.nil?
  x = Link.new(user: s, name: "QA6750 Widget X (cross-sell)", description: "QA6750 cross-sell target",
               price_cents: 3000, native_type: "digital", price_currency_type: "usd")
  x.save!
  x.publish!
end
x.customizable_price = false
x.price_cents = 3000
x.save!(validate: false)
x.prices.alive.each { |p| p.update_columns(price_cents: 3000) }
m "X id=#{x.id} perm=#{x.unique_permalink} price=#{x.price_cents} alive=#{x.alive?}"

# Cross-sell upsell: buying A offers X.
Upsell.where(seller: s, product_id: x.id).each { |u| u.mark_deleted! rescue u.update_columns(deleted_at: Time.current) }
up = Upsell.new(seller: s, product: x, cross_sell: true, name: "QA6750 cross-sell",
                text: "Add QA6750 Widget X")
up.selected_products = [a]
up.save!
m "UPSELL id=#{up.id} cross_sell=#{up.cross_sell?} product=#{up.product.unique_permalink} selected=#{up.selected_products.map(&:unique_permalink).inspect}"

# Universal $1 fixed-amount code, uncapped.
oc = s.offer_codes.find_by(code: "QA6750FIXED")
oc&.destroy!
oc = OfferCode.new(user: s, code: "QA6750FIXED", amount_cents: 100, universal: true, currency_type: "usd")
oc.save!
m "OC code=#{oc.code} cents=#{oc.amount_cents} is_cents=#{oc.is_cents?} universal=#{oc.universal?}"

# Percentage control: a percentage code is NOT once-per-cart, so it must still resolve
# fully on the cross-sell. This is the arm that proves the new branch is keyed on is_cents?.
pc = s.offer_codes.find_by(code: "QA6750PCT")
pc&.destroy!
pc = OfferCode.new(user: s, code: "QA6750PCT", amount_percentage: 10, universal: true)
pc.save!
m "PC code=#{pc.code} pct=#{pc.amount_percentage} is_cents=#{pc.is_cents?}"

def qq(code, pairs)
  products = pairs.to_h { |l, q| [l.unique_permalink, { permalink: l.unique_permalink, quantity: q }] }
  OfferCodeDiscountComputingService.new(code, products).process
end

def dump(tag, r, links)
  pd = r[:products_data]
  names = links.to_h { |l| [l.unique_permalink, l.name] }
  pd.each do |perm, v|
    m "#{tag} line perm=#{perm} name=#{names[perm] || "(cross-sell)"} cents=#{v[:discount][:cents]} type=#{v[:discount][:type]}"
  end
  m "#{tag} lines=#{pd.size} positive_lines=#{pd.values.count { _1[:discount][:cents].to_i.positive? }} discount_sum=#{pd.values.sum { _1[:discount][:cents].to_i }}"
  m "#{tag} error_code=#{r[:error_code].inspect} partial=#{r[:partial_ineligibility_code].inspect}"
end

a.reload; b.reload; x.reload

# ARM 1 — this commit's shape: A + B in cart, fixed $1 code, X pulled in as a cross-sell off A.
r1 = qq("QA6750FIXED", [[a, 1], [b, 1]])
dump("ARM1-FIXED", r1, [a, b, x])

# ARM 2 — percentage control on the identical cart. Not once-per-cart, so every line
# including the cross-sell must carry its own percentage discount.
r2 = qq("QA6750PCT", [[a, 1], [b, 1]])
dump("ARM2-PCT", r2, [a, b, x])

# ARM 3 — single-line cart with the fixed code. The code is spent on A, so the cross-sell
# must be covered at zero. This is the minimal shape the new spec asserts.
r3 = qq("QA6750FIXED", [[a, 1]])
dump("ARM3-FIXED-1LINE", r3, [a, b, x])

m "DONE"
