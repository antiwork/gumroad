# frozen_string_literal: true

# PR 6750 re-arm probe: does b578fa5c1 close the cross-sell overwrite the PR body
# documents as its own second defect? Seeds the same fixtures pr-6750-x-seed.rb
# built (the redeploy reseeded the DB) and drives the service over both hash
# orders, which is the axis the old code was sensitive to.

M = "MARK6750R3"
def m(s) = puts("#{M} #{s}")

s = User.find_by(email: "seller@gumroad.com")
m "seller=#{s.id} revision=#{ENV['REVISION'] || 'n/a'}"

a = Link.find(1)
a.customizable_price = false
a.price_cents = 1000
a.name = "QA6750 Widget A"
a.save!(validate: false)
a.prices.alive.each { |p| p.update_columns(price_cents: 1000) }

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

Upsell.where(seller: s, product_id: x.id).each { |u| (u.mark_deleted! rescue u.update_columns(deleted_at: Time.current)) }
up = Upsell.new(seller: s, product: x, cross_sell: true, name: "QA6750 cross-sell",
                text: "Add QA6750 Widget X")
up.selected_products = [a]
up.save!

oc = s.offer_codes.find_by(code: "QA6750FIXED")
oc&.destroy!
oc = OfferCode.new(user: s, code: "QA6750FIXED", amount_cents: 100, universal: true, currency_type: "usd")
oc.save!

pc = s.offer_codes.find_by(code: "QA6750PCT")
pc&.destroy!
pc = OfferCode.new(user: s, code: "QA6750PCT", amount_percentage: 10, universal: true)
pc.save!

a.reload; b.reload; x.reload
m "SEED A=#{a.unique_permalink}/#{a.price_cents} B=#{b.unique_permalink}/#{b.price_cents} X=#{x.unique_permalink}/#{x.price_cents}"
m "SEED upsell=#{up.id} cross_sell=#{up.cross_sell?} target=#{up.product.unique_permalink} off=#{up.selected_products.map(&:unique_permalink).inspect}"
m "SEED oc=#{oc.code}/#{oc.amount_cents}c is_cents=#{oc.is_cents?} pct=#{pc.code}/#{pc.amount_percentage}"
m "SEED cross_sells_of_A=#{a.available_cross_sells.map { |c| c.product.unique_permalink }.inspect}"

def qq(code, pairs)
  products = pairs.to_h { |l, q| [l.unique_permalink, { permalink: l.unique_permalink, quantity: q }] }
  OfferCodeDiscountComputingService.new(code, products).process
end

def dump(tag, r)
  pd = r[:products_data]
  pd.each { |perm, v| m "#{tag} line #{perm} cents=#{v[:discount][:cents]} type=#{v[:discount][:type]}" }
  sum = pd.values.sum { _1[:discount][:cents].to_i }
  m "#{tag} lines=#{pd.size} positive=#{pd.values.count { _1[:discount][:cents].to_i.positive? }} discount_sum=#{sum}"
  m "#{tag} error=#{r[:error_code].inspect} partial=#{r[:partial_ineligibility_code].inspect}"
  sum
end

# ARM 1 — the shape the body reports as broken: X is BOTH a cart line and a
# cross-sell of A, sent in the order the checkout page renders (newest first).
s1 = dump("ARM1-XFIRST", qq("QA6750FIXED", [[x, 1], [a, 1], [b, 1]]))
raise "ABORT ARM1 expected 100c once-per-cart, got #{s1}" unless s1 == 100

# ARM 2 — the same cart in the opposite order. The old code returned 100c here
# and 0c above; a fix must make the two agree.
s2 = dump("ARM2-AFIRST", qq("QA6750FIXED", [[a, 1], [b, 1], [x, 1]]))
raise "ABORT ARM2 expected 100c, got #{s2}" unless s2 == 100
m "ORDER-INDEPENDENT xfirst=#{s1} afirst=#{s2} agree=#{s1 == s2}"

# ARM 3 — X NOT a cart line: the case the cross-sell branch was written for.
# It must still be covered at zero so the fixed amount is not spent twice.
r3 = qq("QA6750FIXED", [[a, 1], [b, 1]])
s3 = dump("ARM3-CROSSSELL-ONLY", r3)
xr = r3[:products_data][x.unique_permalink]
raise "ABORT ARM3 cross-sell not covered" if xr.nil?
raise "ABORT ARM3 cross-sell should be 0c, got #{xr[:discount][:cents]}" unless xr[:discount][:cents].to_i.zero?
raise "ABORT ARM3 expected 100c total, got #{s3}" unless s3 == 100

# ARM 4 — percentage control. Not once-per-cart, so every line keeps its own
# discount and the cross-sell resolves fully. Proves the branch is keyed on is_cents?.
r4 = qq("QA6750PCT", [[x, 1], [a, 1], [b, 1]])
dump("ARM4-PCT", r4)
raise "ABORT ARM4 percentage lost a line" unless r4[:products_data].values.all? { _1[:discount][:cents].to_i.positive? || _1[:discount][:percents].to_i.positive? }

# PRE-FIX column: what the cross-sell pass did before b578fa5c1 — an unconditional
# write. Recompute ARM1 with the guard removed to produce the "before" cell rather
# than asserting it from prose.
OfferCodeDiscountComputingService.new("QA6750FIXED",
                                      { x.unique_permalink => { permalink: x.unique_permalink, quantity: 1 },
                                        a.unique_permalink => { permalink: a.unique_permalink, quantity: 1 },
                                        b.unique_permalink => { permalink: b.unique_permalink, quantity: 1 } })
src = OfferCodeDiscountComputingService.instance_method(:optimistically_apply_to_applicable_cross_sells)
m "GUARD present_in_head=#{OfferCodeDiscountComputingService.private_instance_methods(false).include?(:optimistically_apply_to_applicable_cross_sells) || src.present?}"

klass = OfferCodeDiscountComputingService
orig = klass.instance_method(:optimistically_apply_to_applicable_cross_sells)
klass.send(:define_method, :optimistically_apply_to_applicable_cross_sells) do |products_data, link|
  link.available_cross_sells.each do |cross_sell|
    # deliberately NO `next if products_data.key?(...)` — this is the pre-fix body
    offer_code = send(:find_applicable_offer_code_for, cross_sell.product)
    next unless offer_code
    rd = offer_code.evaluate_for_buyer(send(:buyer), product: cross_sell.product)
    next unless rd
    rd = rd.merge(cents: 0) if send(:once_per_cart?, offer_code) && send(:already_applied?, offer_code)
    products_data[cross_sell.product.unique_permalink] = { discount: rd }
  end
end
pre1 = dump("PREFIX-XFIRST", qq("QA6750FIXED", [[x, 1], [a, 1], [b, 1]]))
pre2 = dump("PREFIX-AFIRST", qq("QA6750FIXED", [[a, 1], [b, 1], [x, 1]]))
klass.send(:define_method, :optimistically_apply_to_applicable_cross_sells, orig)
m "PREFIX xfirst=#{pre1} afirst=#{pre2} order_dependent=#{pre1 != pre2}"
m "POSTFIX xfirst=#{s1} afirst=#{s2} order_dependent=#{s1 != s2}"
raise "ABORT prefix arm did not reproduce the reported 0c" unless pre1.zero?

# CHARGE side, unchanged by this PR — the body's headline divergence.
charge = [a, b, x].map do |l|
  Purchase.new(link: l, seller: s, price_cents: l.price_cents, displayed_price_cents: l.price_cents,
               offer_code: oc, quantity: 1).send(:offer_amount_off, l.price_cents)
end
m "CHARGE per_line=#{charge.inspect} sum=#{charge.sum} vs QUOTE=#{s1}"

m "DONE"
