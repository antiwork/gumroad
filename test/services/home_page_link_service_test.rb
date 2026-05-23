# frozen_string_literal: true

require "test_helper"

class HomePageLinkServiceTest < ActiveSupport::TestCase
  %i[privacy terms about features university pricing affiliates prohibited].each do |page|
    test ".#{page} returns the full URL of the page" do
      assert_equal "#{UrlService.root_domain_with_protocol}/#{page}", HomePageLinkService.public_send(page)
    end
  end

  test ".root returns the root domain with protocol" do
    assert_equal UrlService.root_domain_with_protocol, HomePageLinkService.root
  end
end
