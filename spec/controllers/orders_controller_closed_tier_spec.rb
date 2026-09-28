# frozen_string_literal: true

require "spec_helper"

describe OrdersController do
  let(:seller) { create(:user) }
  let(:product) { create(:membership_product, user: seller) }
  let(:tier) { product.tiers.first }

  before do
    cookies[:_gumroad_guid] = SecureRandom.uuid
    Feature.activate_user(:close_membership_tier_to_new_buyers, seller)
    tier.update!(closed_to_new_purchases: true)
  end

  it "rejects a new purchase of a closed tier the same way as a sold-out one" do
    expect do
      post :create, params: {
        email: "buyer@example.com",
        line_items: [{
          uid: "unique-id-0",
          permalink: product.unique_permalink,
          perceived_price_cents: product.default_price.price_cents,
          quantity: 1,
          price_id: product.default_price.external_id,
          variants: [tier.external_id],
        }],
      }
    end.not_to change { Purchase.successful.count }

    line_item = response.parsed_body["line_items"]["unique-id-0"]
    expect(line_item["success"]).to be(false)
    expect(line_item["error_message"]).to eq("Sold out, please go back and pick another option.")
    expect(Purchase.last.error_code).to eq(PurchaseErrorCode::VARIANT_SOLD_OUT)
  end
end
