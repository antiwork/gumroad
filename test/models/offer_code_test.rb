# frozen_string_literal: true

require "test_helper"

class OfferCodeTest < ActiveSupport::TestCase
  test "duration_in_billing_cycles fails when it exceeds the maximum storable value" do
    product = create_product
    offer_code = OfferCode.new(
      user: product.user,
      products: [product],
      code: "overflow",
      amount_cents: 100,
      currency_type: product.user.currency_type,
      duration_in_billing_cycles: 2_147_483_648
    )

    assert_not offer_code.valid?
    assert_includes offer_code.errors.full_messages, "Sorry, the duration entered is too large."
  end
end
