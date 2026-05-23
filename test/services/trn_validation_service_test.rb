# frozen_string_literal: true

require "test_helper"

class TrnValidationServiceTest < ActiveSupport::TestCase
  test "returns true when a valid TRN is provided" do
    assert_equal true, TrnValidationService.new("123456789012345").process
  end

  test "returns false when a nil TRN is provided" do
    assert_equal false, TrnValidationService.new(nil).process
  end

  test "returns false when a blank TRN is provided" do
    assert_equal false, TrnValidationService.new("   ").process
  end

  test "returns false when a TRN with an invalid length is provided" do
    assert_equal false, TrnValidationService.new("12345").process
    assert_equal false, TrnValidationService.new("1234567890123456").process
  end
end
