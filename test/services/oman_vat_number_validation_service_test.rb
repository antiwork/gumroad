# frozen_string_literal: true

require "test_helper"

class OmanVatNumberValidationServiceTest < ActiveSupport::TestCase
  test "returns true when a valid VAT number is provided" do
    assert_equal true, OmanVatNumberValidationService.new("OM1234567890").process
  end

  test "returns false when a nil VAT number is provided" do
    assert_equal false, OmanVatNumberValidationService.new(nil).process
  end

  test "returns false when a blank VAT number is provided" do
    assert_equal false, OmanVatNumberValidationService.new("   ").process
  end

  test "returns false when a VAT number with an invalid format is provided" do
    assert_equal false, OmanVatNumberValidationService.new("OM123456").process
    assert_equal false, OmanVatNumberValidationService.new("ON1234567890").process
    assert_equal false, OmanVatNumberValidationService.new("om1234567890").process
    assert_equal false, OmanVatNumberValidationService.new("1234567890").process
    assert_equal false, OmanVatNumberValidationService.new("OMABCDEFGHIJ").process
  end
end
