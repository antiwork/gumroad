# frozen_string_literal: true

describe InvalidateProductCacheWorker do
  describe "#perform" do
    before do
      @product = create(:product)
    end

    it "expires the product cache" do
      expect_any_instance_of(Link).to receive(:invalidate_cache).once
      described_class.new.perform(@product.id)
    end
  end
end
