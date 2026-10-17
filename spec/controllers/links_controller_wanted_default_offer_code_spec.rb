# frozen_string_literal: true

require "spec_helper"

describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let(:product) do
    create(:membership_product_with_preset_tiered_pricing, user: seller,
                                                           recurrence_price_values: [{ monthly: { enabled: true, price: 10 } }, { monthly: { enabled: true, price: 100 } }])
  end
  let(:owned) { create(:product, user: seller, price_cents: 10_00) }
  let(:buyer) { create(:user) }

  before do
    seller.offer_codes.create!(code: "SHOP5", amount_cents: 5_00, currency_type: "usd", universal: true, products: [], auto_apply: true)
    renewal = create(:offer_code, user: seller, products: [product], ownership_products: [owned], existing_customers_only: true,
                                  code: "RENEW20", amount_cents: nil, amount_percentage: 20, currency_type: nil)
    product.update!(default_offer_code: renewal)
    create(:purchase, purchaser: buyer, link: owned, seller:, price_cents: owned.price_cents)
    Current.reset
    @request.host = URI.parse(seller.subdomain_with_protocol).host
    sign_in buyer
  end

  def checkout_params_for(tier_name, code:)
    get :show, params: { id: product.unique_permalink, wanted: "true", option: product.tiers.find_by!(name: tier_name).external_id, code: }.compact

    expect(response).to be_redirect
    Rack::Utils.parse_query(URI.parse(response.location).query)
  end

  # The product page's initial CTA already carries the sale's code before the buyer picks a tier.
  [nil, "SHOP5"].each do |code|
    context code ? "when the link carries the sale's code" : "when the link carries no code" do
      it "forwards a qualifying buyer's percent default when it beats a fixed sale on the tier they chose" do
        expect(checkout_params_for("Second Tier", code:)).to include("code" => "RENEW20", "price" => "10000")
      end

      it "forwards the fixed sale when it beats the percent default on the tier they chose" do
        expect(checkout_params_for("First Tier", code:)).to include("code" => "SHOP5", "price" => "1000")
      end
    end
  end
end
