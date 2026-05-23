# frozen_string_literal: true

require "test_helper"

class SocialShareUrlHelperTest < ActionView::TestCase
  test "twitter_url generates a twitter share url" do
    expected = "https://twitter.com/intent/tweet?text=You+%26+I:%20https://example.com"
    assert_equal expected, twitter_url("https://example.com", "You & I")
  end

  test "facebook_url generates a facebook share url with text" do
    expected = "https://www.facebook.com/sharer/sharer.php?u=https://example.com&quote=You+%2A+I"
    assert_equal expected, facebook_url("https://example.com", "You * I")
  end

  test "facebook_url generates a facebook share url without text" do
    expected = "https://www.facebook.com/sharer/sharer.php?u=https://example.com"
    assert_equal expected, facebook_url("https://example.com")
  end
end
