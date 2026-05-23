# frozen_string_literal: true

require "test_helper"

class MailerHelperTest < ActionView::TestCase
  test "from_email_address_name returns the name when it has no special characters" do
    assert_equal "John The Creator", from_email_address_name("John The Creator")
  end

  test "from_email_address_name strips colons" do
    assert_equal "John The Creator", from_email_address_name("John: The Creator")
  end
end
