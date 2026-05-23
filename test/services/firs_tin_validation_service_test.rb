# frozen_string_literal: true

require "test_helper"

class FirsTinValidationServiceTest < ActiveSupport::TestCase
  test "returns true when a valid FIRS TIN is provided" do
    assert_equal true, FirsTinValidationService.new("12345678-1234").process
  end

  test "returns false when a nil FIRS TIN is provided" do
    assert_equal false, FirsTinValidationService.new(nil).process
  end

  test "returns false when a blank FIRS TIN is provided" do
    assert_equal false, FirsTinValidationService.new("   ").process
  end

  test "returns false when a FIRS TIN with an invalid format is provided" do
    assert_equal false, FirsTinValidationService.new("123456781234").process
    assert_equal false, FirsTinValidationService.new("12345678-123").process
    assert_equal false, FirsTinValidationService.new("1234567-1234").process
    assert_equal false, FirsTinValidationService.new("abcdefgh-1234").process
  end
end
