# frozen_string_literal: true

require "test_helper"

class BalanceSearchableTest < ActiveSupport::TestCase
  self.described_class = Balance::Searchable



  context_ Balance::Searchable do
  test "includes ElasticsearchModelAsyncCallbacks" do
      expect(Balance).to include(ElasticsearchModelAsyncCallbacks)
    end
  end
end
