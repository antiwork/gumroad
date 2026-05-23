# frozen_string_literal: true

require "test_helper"

class KraPinValidationServiceTest < ActiveSupport::TestCase
  test "returns true when a valid KRA PIN is provided" do
    assert_equal true, KraPinValidationService.new("A123456789P").process
  end

  test "returns false when a nil KRA PIN is provided" do
    assert_equal false, KraPinValidationService.new(nil).process
  end

  test "returns false when a blank KRA PIN is provided" do
    assert_equal false, KraPinValidationService.new("   ").process
  end

  test "returns false when a KRA PIN with an invalid format is provided" do
    assert_equal false, KraPinValidationService.new("123456789").process
    assert_equal false, KraPinValidationService.new("A12345678PP").process
    assert_equal false, KraPinValidationService.new("123456789P").process
    assert_equal false, KraPinValidationService.new("A123456789").process
  end
end
