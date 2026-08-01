# frozen_string_literal: true

M = "MARK6750S"
def m(s) = puts("#{M} #{s}")

s = User.find_by(email: "seller@gumroad.com")
a = Link.find(1)
b = s.links.alive.find_by(name: "QA6750 Widget B")
x = s.links.alive.find_by(name: "QA6750 Widget X (cross-sell)")

# Trace every write into products_data so the overwrite is visible rather than inferred.
WRITES = []
OfferCodeDiscountComputingService.class_eval do
  orig = instance_method(:optimistically_apply_to_applicable_cross_sells)
  # NOTE: `private define_method(:x) do ... end` binds the block to `private`, not to
  # define_method — it dies with "tried to create Proc object without a block". Parenthesise.
  define_method(:optimistically_apply_to_applicable_cross_sells) do |products_data, link|
    before = products_data.transform_values { _1[:discount][:cents] }
    orig.bind_call(self, products_data, link)
    after = products_data.transform_values { _1[:discount][:cents] }
    WRITES << "cross_sell_pass for=#{link.unique_permalink} before=#{before.inspect} after=#{after.inspect}"
  end
  private :optimistically_apply_to_applicable_cross_sells
end

products = [[x, 1], [a, 1], [b, 1]].to_h { |l, q| [l.unique_permalink, { permalink: l.unique_permalink, quantity: q }] }
r = OfferCodeDiscountComputingService.new("QA6750FIXED", products).process
WRITES.each { |w| m w }
m "FINAL #{r[:products_data].transform_values { _1[:discount][:cents] }.inspect}"

# Is the cross-sell product a real cart line here?
m "x_is_cart_line=#{products.key?(x.unique_permalink)} a_cross_sells=#{a.available_cross_sells.map { _1.product.unique_permalink }.inspect}"
m "DONE"
