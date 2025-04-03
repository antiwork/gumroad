# frozen_string_literal: true

require "spec_helper"

describe CustomerSurchargeController, :vcr do
  include ManageSubscriptionHelpers

  before do
    @user = create(:user)
    @product = create(:product, user: @user)
    @physical_product = create(:physical_product, user: @user)
    country_code = Compliance::Countries::USA.alpha2
    @physical_product.shipping_destinations << create(:shipping_destination, country_code:, one_item_rate_cents: 20)
    @zip_tax_rate = create(:zip_tax_rate, combined_rate: 0.1, zip_code: nil, state: "CA")
  end

  it "returns 0 if price input is invalid" do
    post "calculate_all", params: { products: [{ permalink: @physical_product.unique_permalink, price: "invalid", quantity: 1 }] }, as: :json
    expect(response.parsed_body).to eq({
      vat_id_valid: false,
      has_vat_id_input: false,
      shipping_rate_cents: 0,
      tax_cents: 0,
      tax_included_cents: 0,
      subtotal: 0,
    }.as_json)
  end

  it "returns the correct non-zero tax value when buyer location is EU and no VAT ID is provided" do
    create(:zip_tax_rate, combined_rate: 0.19, country: "DE", state: nil, zip_code: nil, is_seller_responsible: false)

    post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1 }], postal_code: 10115, country: "DE" }, as: :json
    expect(response.parsed_body).to eq({
      vat_id_valid: false,
      has_vat_id_input: true,
      shipping_rate_cents: 0,
      tax_cents: 19,
      tax_included_cents: 0,
      subtotal: 100,
    }.as_json)
  end

  it "returns the correct tax value and an invalid VAT ID status when buyer location is EU and the VAT ID provided is invalid" do
    create(:zip_tax_rate, combined_rate: 0.19, country: "DE", state: nil, zip_code: nil, is_seller_responsible: false)

    post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1 }], postal_code: 10115, country: "DE", vat_id: "DE123" }, as: :json

    expect(response.parsed_body).to eq({
      vat_id_valid: false,
      has_vat_id_input: true,
      shipping_rate_cents: 0,
      tax_cents: 19,
      tax_included_cents: 0,
      subtotal: 100,
    }.as_json)
  end

  it "returns the correct tax value when buyer location is British Columbia Canada" do
    post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1, recommended_by: "discover" }], postal_code: "V6B 2L3", country: "CA", state: "BC" }, as: :json

    expect(response.parsed_body).to eq({
      vat_id_valid: false,
      has_vat_id_input: false,
      shipping_rate_cents: 0,
      tax_cents: 12,
      tax_included_cents: 0,
      subtotal: 100,
    }.as_json)
  end

  it "returns tax as 0 when buyer location is EU and a valid VAT ID is provided" do
    create(:zip_tax_rate, combined_rate: 0.19, country: "DE", state: nil, zip_code: nil)

    post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1 }], postal_code: 10115, country: "DE", vat_id: "IE6388047V" }, as: :json

    expect(response.parsed_body).to eq({
      vat_id_valid: true,
      has_vat_id_input: false,
      shipping_rate_cents: 0,
      tax_cents: 0,
      tax_included_cents: 0,
      subtotal: 100,
    }.as_json)
  end

  it "allows querying multiple products at once" do
    post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1 }, { permalink: @physical_product.unique_permalink, price: 200, quantity: 3 }], postal_code: 98039, country: "US" }, as: :json
    expect(response.parsed_body).to eq({
      vat_id_valid: false,
      has_vat_id_input: false,
      shipping_rate_cents: 20,
      tax_cents: 32,
      tax_included_cents: 0,
      subtotal: 300,
    }.as_json)
  end

  context "for a subscription", :vcr do
    context "when original purchase was charged VAT" do
      before :each do
        setup_subscription_with_vat
      end

      context "and the buyer is in the EU" do
        it "uses the original purchase's location info" do
          post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 500, quantity: 1, subscription_id: @subscription.external_id }], postal_code: 10115, country: "DE" }, as: :json

          expect(response.parsed_body["tax_cents"]).to eq 100
        end
      end

      context "and the buyer is currently not in the EU" do
        it "still uses the original purchase's location info" do
          post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 500, quantity: 1, subscription_id: @subscription.external_id }], postal_code: 94_301, country: "US" }, as: :json

          expect(response.parsed_body["tax_cents"]).to eq 100
        end
      end
    end

    context "when original purchase was not charged VAT" do
      before :each do
        setup_subscription
      end

      it "uses the original purchase's location info" do
        post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 500, quantity: 1, subscription_id: @subscription.external_id }] }, as: :json

        expect(response.parsed_body["tax_cents"]).to eq 0
      end

      context "and the buyer is currently in the EU" do
        it "still uses the original purchase's location info" do
          post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 500, quantity: 1, subscription_id: @subscription.external_id }], postal_code: 10115, country: "DE" }, as: :json

          expect(response.parsed_body["tax_cents"]).to eq 0
          expect(response.parsed_body["tax_info"]).to be_nil
        end
      end
    end

    context "when original purchase had a VAT ID" do
      it "uses the VAT ID" do
        allow_any_instance_of(VatValidationService).to receive(:process).and_return(true)
        setup_subscription_with_vat(vat_id: "FR123456789")

        post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 500, quantity: 1, subscription_id: @subscription.external_id }] }, as: :json

        expect(response.parsed_body["tax_cents"]).to eq 0
        expect(response.parsed_body["vat_id_valid"]).to eq true
      end
    end
  end
end
