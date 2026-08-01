# frozen_string_literal: true

ActiveRecord::Base.logger = nil
Rails.logger.level = Logger::FATAL

out = []
def m(out, s) = out << s

s = User.find_by(email: "seller@gumroad.com")
fixed = s.offer_codes.find_by(code: "QA6750FIXED")
pct   = s.offer_codes.find_by(code: "QA6750PCT")
a = Link.find_by(unique_permalink: "demo")
b = Link.find_by(unique_permalink: "c")
x = Link.find_by(unique_permalink: "of")

m out, "CODE fixed=#{fixed.code} cents=#{fixed.amount_cents} is_cents=#{fixed.is_cents?}"
m out, "CODE pct=#{pct.code} pct=#{pct.amount_percentage} is_cents=#{pct.is_cents?}"
m out, "LINK A=#{a.unique_permalink}/#{a.price_cents} B=#{b.unique_permalink}/#{b.price_cents} X=#{x&.unique_permalink}/#{x&.price_cents}"

def qq(code, pairs)
  products = pairs.to_h { |l, q| [l.unique_permalink, { permalink: l.unique_permalink, quantity: q }] }
  OfferCodeDiscountComputingService.new(code, products).process
end

def cents(r) = r[:products_data].transform_values { |v| v[:discount][:cents] || "#{v[:discount][:percents]}%" }

def sum(r)   = r[:products_data].values.sum { |v| v[:discount][:cents].to_i }

def flag!(oc, on)
  oc.once_per_cart = on
  oc.save!(validate: false)
  oc.reload
end

# ================= THE HEADLINE PAIR: identical cart, flag OFF vs ON ==========
flag!(fixed, false)
r = qq("QA6750FIXED", [[a, 1], [b, 1]])
m out, "ARM1 flag=OFF(DEFAULT) data=#{cents(r).inspect} error=#{r[:error_code].inspect} partial=#{r[:partial_ineligibility_code].inspect}"
m out, "ARM1 subtotal=2000 discount_sum=#{sum(r)} quoted_total=#{2000 - sum(r)}   <- today's behaviour, per line"

flag!(fixed, true)
r = qq("QA6750FIXED", [[a, 1], [b, 1]])
m out, "ARM2 flag=ON          data=#{cents(r).inspect} error=#{r[:error_code].inspect} partial=#{r[:partial_ineligibility_code].inspect}"
m out, "ARM2 subtotal=2000 discount_sum=#{sum(r)} quoted_total=#{2000 - sum(r)}   <- opted in, once per cart"

# ================= THREE LINES: once per CART, not once per pair =============
if x
  flag!(fixed, false)
  r = qq("QA6750FIXED", [[a, 1], [b, 1], [x, 1]])
  m out, "ARM3 3-line flag=OFF data=#{cents(r).inspect} discount_sum=#{sum(r)} total=#{5000 - sum(r)}"
  flag!(fixed, true)
  r = qq("QA6750FIXED", [[a, 1], [b, 1], [x, 1]])
  m out, "ARM3 3-line flag=ON  data=#{cents(r).inspect} discount_sum=#{sum(r)} total=#{5000 - sum(r)}"
end

# ================= CONTROLS THAT MUST NOT MOVE ===============================
flag!(pct, true)
r = qq("QA6750PCT", [[a, 1], [b, 1]])
m out, "ARM4 pct flag=ON(set) is_cents=#{pct.is_cents?} data=#{cents(r).inspect} error=#{r[:error_code].inspect}  <- unchanged, branch keyed on is_cents?"
flag!(pct, false)
r = qq("QA6750PCT", [[a, 1], [b, 1]])
m out, "ARM4 pct flag=OFF     data=#{cents(r).inspect}  <- identical to flag=ON"

# ================= FLAG STORAGE / DEFAULTS ===================================
flag!(fixed, true)
m out, "ARM5 flags_col=#{fixed.flags} once_per_cart=#{fixed.once_per_cart?} cancellation=#{fixed.is_cancellation_discount?} via_cli=#{fixed.created_via_cli?}  <- bit 3, siblings untouched"
flag!(fixed, false)
m out, "ARM5 flags_col=#{fixed.flags} once_per_cart=#{fixed.once_per_cart?}"
fresh = OfferCode.new(user: s, code: "QA6750FRESH", amount_cents: 250, universal: true)
m out, "ARM5 brand_new_fixed_code once_per_cart=#{fresh.once_per_cart?} flags=#{fresh.flags.inspect}  <- opt-in default"
on = OfferCode.where("flags & 4 != 0").count
tot = OfferCode.count
m out, "ARM5 codes_platform_wide_with_flag_on=#{on}/#{tot}  <- deploy alone flips nothing"

# ================= CHARGE LAYER: still unfixed (step 2) ======================
flag!(fixed, true)
r = qq("QA6750FIXED", [[a, 1], [b, 1]])
charged = [a, b].map do |l|
  p = Purchase.new(link: l, seller: s, price_cents: 1000, displayed_price_cents: 1000, offer_code: fixed, quantity: 1)
  p.send(:offer_amount_off, 1000)
end
m out, "ARM6 flag=ON QUOTE discount=#{sum(r)} (total #{2000 - sum(r)})  CHARGE per_line=#{charged.inspect} sum=#{charged.sum} (total #{2000 - charged.sum})"
m out, "ARM6 divergence=#{charged.sum - sum(r)}c  <- headline defect UNCHANGED by this commit"

# leave fixture opted IN for the browser leg
flag!(fixed, true)
m out, "FINAL QA6750FIXED once_per_cart=#{fixed.once_per_cart?} flags=#{fixed.flags}"

puts "\n===MARKS===\n" + out.join("\n")
