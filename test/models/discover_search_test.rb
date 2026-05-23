# frozen_string_literal: true

require "test_helper"

class DiscoverSearchTest < ActiveSupport::TestCase
  self.described_class = DiscoverSearch



  context_ DiscoverSearch do
  test "can be created" do
      create(:discover_search)
    end
  end
end
