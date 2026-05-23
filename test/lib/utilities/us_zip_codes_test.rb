# frozen_string_literal: true

require "test_helper"

class UsZipCodesTest < ActiveSupport::TestCase
  test "identify_state_code returns the state for a known zip code" do
    assert_equal "CA", UsZipCodes.identify_state_code("94104")
  end

  test "identify_state_code ignores leading whitespace" do
    assert_equal "CA", UsZipCodes.identify_state_code("  94104")
  end

  test "identify_state_code ignores trailing whitespace" do
    assert_equal "CA", UsZipCodes.identify_state_code("94104  ")
  end

  test "identify_state_code accepts zip+4 with a hyphen" do
    assert_equal "CA", UsZipCodes.identify_state_code("94104-5401")
  end

  test "identify_state_code accepts zip+4 with a single space" do
    assert_equal "CA", UsZipCodes.identify_state_code("94104 5401")
  end

  test "identify_state_code accepts zip+4 with no separator" do
    assert_equal "CA", UsZipCodes.identify_state_code("941045401")
  end

  test "identify_state_code returns nil when shorter than 5 digits" do
    assert_nil UsZipCodes.identify_state_code("9410")
  end

  test "identify_state_code returns nil when it contains non-digits" do
    assert_nil UsZipCodes.identify_state_code("94l04")
  end

  test "identify_state_code returns nil for an invalid zip+4 structure" do
    assert_nil UsZipCodes.identify_state_code("94104-540")
  end

  test "identify_state_code returns nil for nil input" do
    assert_nil UsZipCodes.identify_state_code(nil)
  end

  test "identify_state_code returns nil for an empty string" do
    assert_nil UsZipCodes.identify_state_code("")
  end
end
