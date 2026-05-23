# frozen_string_literal: true

require "test_helper"

class StripeApplePayDomainTest < ActiveSupport::TestCase
  self.described_class = StripeApplePayDomain



  context_ StripeApplePayDomain do
  test "validates presence of attributes" do
      record = StripeApplePayDomain.create()
      expect(record.errors.messages).to eq(
        user: ["can't be blank"],
        domain: ["can't be blank"],
        stripe_id: ["can't be blank"],
      )
    end
  end
end
