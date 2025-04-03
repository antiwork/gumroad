# frozen_string_literal: true

describe DeleteWishlistProductsJob do
  describe "#perform" do
    let(:product) { create(:product) }

    let!(:wishlist_product) { create(:wishlist_product, product:) }
    let!(:unrelated_wishlist_product) { create(:wishlist_product) }

    it "deletes associated wishlist products" do
      product.mark_deleted!
      described_class.new.perform(product.id)
      expect(wishlist_product.reload).to be_deleted
      expect(unrelated_wishlist_product).not_to be_deleted
    end

    it "does nothing if the product was not actually deleted" do
      described_class.new.perform(product.id)
      expect(wishlist_product.reload).not_to be_deleted
    end
  end
end
