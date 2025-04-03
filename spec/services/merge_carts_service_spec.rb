# frozen_string_literal: true

require "spec_helper"

describe MergeCartsService do
  describe "#process" do
    let!(:user) { create(:user) }
    let(:browser_guid) { SecureRandom.uuid }

    context "when source cart is nil" do
      it "updates the details of the target cart" do
        cart = create(:cart, user:, browser_guid: "old-browser-guid")
        expect do
          described_class.new(source_cart: nil, target_cart: cart, user:, browser_guid:).process
        end.to change { cart.reload.browser_guid }.from("old-browser-guid").to(browser_guid)
          .and change { cart.email }.from(nil).to(user.email)
          .and not_change { cart.slice(:user_id, :deleted_at) }
          .and not_change { Cart.alive.count }
      end
    end

    context "target cart is nil" do
      it "updates the details of the source cart" do
        cart = create(:cart, :guest, browser_guid:)
        expect do
          expect do
            described_class.new(source_cart: cart, target_cart: nil, user:, browser_guid:).process
          end.to change { cart.reload.user_id }.from(nil).to(user.id)
        end.to_not change { cart.browser_guid }

        expect(Cart.alive.sole.id).to eq(cart.id)
        expect(cart.email).to eq(user.email)
        expect(cart.browser_guid).to eq(browser_guid)
      end
    end

    it "does nothing if the source cart is the same as the target cart" do
      cart = create(:cart, user:, browser_guid:)
      expect do
        expect do
          described_class.new(source_cart: cart, target_cart: cart, user:, browser_guid:).process
        end.to_not change { Cart.alive.count }
      end.to_not change { cart.reload }
    end

    it "deletes the source cart when both source and target carts do not have alive cart products" do
      source_cart = create(:cart, :guest, browser_guid: SecureRandom.uuid, email: "source@example.com")
      target_cart = create(:cart, :guest, browser_guid:)
      expect do
        described_class.new(source_cart:, target_cart:, browser_guid:).process
      end.to change { Cart.alive.count }.from(2).to(1)
      expect(Cart.alive.sole.id).to eq(target_cart.id)
      expect(target_cart.reload.email).to eq("source@example.com")
    end

    it "merges the cart products, discount codes and other attributes from source cart to the target cart" do
      product1 = create(:product)
      product2 = create(:product)
      product2_variant = create(:variant, variant_category: create(:variant_category, link: product2))
      product3 = create(:product)
      source_cart = create(:cart, :guest, browser_guid: SecureRandom.uuid, return_url: "https://example.com/source", discount_codes: [{ code: "ABC123", fromUrl: false }, { code: "XYZ789", fromUrl: false }], reject_ppp_discount: true)
      target_cart = create(:cart, :guest, browser_guid:, discount_codes: [{ code: "DEF456", fromUrl: false }, { code: "ABC123", fromUrl: false }])
      create(:cart_product, cart: source_cart, product: product1)
      create(:cart_product, cart: source_cart, product: product2, option: product2_variant)
      create(:cart_product, cart: target_cart, product: product3)

      expect do
        expect do
          described_class.new(source_cart:, target_cart:, browser_guid:).process
        end.to change { Cart.alive.count }.from(2).to(1)
      end.to change { target_cart.reload.cart_products.count }.from(1).to(3)

      expect(Cart.alive.sole.id).to eq(target_cart.id)
      expect(target_cart.return_url).to eq("https://example.com/source")
      expect(target_cart.discount_codes.map { _1["code"] }).to eq(["DEF456", "ABC123", "XYZ789"])
      expect(target_cart.reject_ppp_discount).to be(true)
      expect(target_cart.alive_cart_products.pluck(:product_id, :option_id)).to eq([[product1.id, nil], [product2.id, product2_variant.id], [product3.id, nil]])
      expect(target_cart.browser_guid).to eq(browser_guid)
      expect(target_cart.email).to be_nil
    end
  end
end
