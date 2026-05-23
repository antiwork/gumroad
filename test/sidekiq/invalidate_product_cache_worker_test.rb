# frozen_string_literal: true

require "test_helper"

class InvalidateProductCacheWorkerTest < ActiveSupport::TestCase
  self.described_class = InvalidateProductCacheWorker


  context_ InvalidateProductCacheWorker do
  context_ "#perform" do
      before do
        @product = create(:product)
      end

  test "expires the product cache" do
        expect_any_instance_of(Link).to receive(:invalidate_cache).once
        described_class.new.perform(@product.id)
      end
    end
  end
end
