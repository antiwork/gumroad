# frozen_string_literal: true

M = "MARK6750R"
def m(s) = puts("#{M} #{s}")

s = User.find_by(email: "seller@gumroad.com")
a = Link.find(1)
b = s.links.alive.find_by(name: "QA6750 Widget B")
x = s.links.alive.find_by(name: "QA6750 Widget X (cross-sell)")

def qq(code, pairs)
  products = pairs.to_h { |l, q| [l.unique_permalink, { permalink: l.unique_permalink, quantity: q }] }
  OfferCodeDiscountComputingService.new(code, products).process
end

def sum(r) = r[:products_data].values.sum { _1[:discount][:cents].to_i }

# POST-FIX (deployed head 7c5de31b0b9e), cross-sell product listed first — the order the
# checkout page actually sends after the buyer adds the cross-sell (cart renders newest first).
post = qq("QA6750FIXED", [[x, 1], [a, 1], [b, 1]])
m "POSTFIX XFIRST sum=#{sum(post)} lines=#{post[:products_data].transform_values { _1[:discount][:cents] }.inspect}"
m "POSTFIX XFIRST error=#{post[:error_code].inspect} partial=#{post[:partial_ineligibility_code].inspect}"

# PRE-FIX: restore the parent commit's cross-sell method VERBATIM (7c5de31b0b9e^).
OfferCodeDiscountComputingService.class_eval do
  private def optimistically_apply_to_applicable_cross_sells(products_data, link)
    link.available_cross_sells.each do |cross_sell|
      offer_code = find_applicable_offer_code_for(cross_sell.product)
      next unless offer_code

      resolved_discount = offer_code.evaluate_for_buyer(buyer, product: cross_sell.product)
      next unless resolved_discount

      products_data[cross_sell.product.unique_permalink] = { discount: resolved_discount }
    end
  end
end

pre = qq("QA6750FIXED", [[x, 1], [a, 1], [b, 1]])
m "PREFIX  XFIRST sum=#{sum(pre)} lines=#{pre[:products_data].transform_values { _1[:discount][:cents] }.inspect}"

m "DONE"
