# frozen_string_literal: true

require "test_helper"

class TraTinValidationServiceTest < ActiveSupport::TestCase
  test "returns true when a valid Tanzania TIN is provided" do
    assert_equal true, TraTinValidationService.new("12-345678-A").process
  end

  test "returns false when a nil TIN is provided" do
    assert_equal false, TraTinValidationService.new(nil).process
  end

  test "returns false when a blank TIN is provided" do
    assert_equal false, TraTinValidationService.new("   ").process
  end

  test "returns false when a TIN with an invalid format is provided" do
    # Wrong first segment length
    assert_equal false, TraTinValidationService.new("123-45678-B").process
    # Wrong middle segment length
    assert_equal false, TraTinValidationService.new("12-34567-A").process
    # Number instead of letter
    assert_equal false, TraTinValidationService.new("12-345678-1").process
    # Missing hyphens
    assert_equal false, TraTinValidationService.new("12345678A").process
    # Letters instead of numbers
    assert_equal false, TraTinValidationService.new("ab-345678-A").process
  end
end
