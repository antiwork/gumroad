# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "merge guest cart with user cart" do
  let(:browser_guid) { "123" }
  let(:guest_cart) { create(:cart, :guest, browser_guid:) }
  let(:user_cart) { create(:cart, user:, browser_guid:) }
  let(:product1) { create(:product) }
  let(:product2) { create(:product) }
  let(:product2_variant) { create(:variant, variant_category: create(:variant_category, link: product2)) }
  let(:product3) { create(:product) }
  let!(:guest_cart_product1) { create(:cart_product, cart: guest_cart, product: product1) }
  let!(:guest_cart_product2) { create(:cart_product, cart: guest_cart, product: product2, option: product2_variant) }
  let!(:user_cart_product) { create(:cart_product, cart: user_cart, product: product3) }
  let(:expects_json_response) { false }

  it "merges the guest cart with the user's cart" do
    cookies[:_gumroad_guid] = browser_guid

    expect(MergeCartsService).to receive(:new).with(source_cart: guest_cart, target_cart: user_cart, user:, browser_guid:).and_call_original

    expect do
      expect do
        call_action
      end.not_to change { Cart.count }
    end.to change { user_cart.reload.alive_cart_products.count }.from(1).to(3)

    if expects_json_response
      expect(response).to be_successful
      expect(response.parsed_body["redirect_location"]).to eq(expected_redirect_location)
    else
      expect(response).to redirect_to(expected_redirect_location)
    end

    expect(guest_cart.reload.deleted?).to be(true)
    expect(user_cart.reload.deleted?).to be(false)
    expect(user_cart.user).to eq(user)
    expect(user_cart.alive_cart_products.pluck(:product_id, :option_id)).to match_array([[product1.id, nil], [product2.id, product2_variant.id], [product3.id, nil]])
  end
end
