# frozen_string_literal: true

require "spec_helper"

describe OfferCodesController do
  describe "#compute_discount" do
    let(:product) { create(:product, price_cents: 500) }
    let(:offer_code) { create(:offer_code, products: [product], max_purchase_count: 2) }
    let(:offer_code_params) do
      {
        code: offer_code.code,
        products: {
          product.unique_permalink => {
            permalink: product.unique_permalink,
            quantity: 2
          }
        }
      }
    end

    it "explains why only one option of a product receives the discount" do
      category = create(:variant_category, link: product)
      eligible = create(:variant, variant_category: category)
      ineligible = create(:variant, variant_category: category)
      offer_code.variants = [eligible]
      get :compute_discount, params: {
        code: offer_code.code,
        products: {
          "0" => { permalink: product.unique_permalink, quantity: 1, variant_external_id: ineligible.external_id },
          "1" => { permalink: product.unique_permalink, quantity: 1, variant_external_id: eligible.external_id },
        }
      }

      expect(response.parsed_body).to include(
        "valid" => true,
        "notice" => "The code applies to some items. The selected options for the other items are not eligible."
      )
      expect(response.parsed_body["products_data"].keys).to eq([product.unique_permalink])
    end

    it "returns an error in response when offer code is invalid" do
      offer_code_params[:code] = "invalid_offer"
      get :compute_discount, params: offer_code_params

      expect(response.parsed_body).to eq({ "error_message" => "Sorry, the discount code you wish to use is invalid.", "error_code" => "invalid_offer", "valid" => false })
    end

    it "applies a code pasted with leading whitespace" do
      offer_code_params[:code] = " #{offer_code.code}"
      get :compute_discount, params: offer_code_params

      expect(response.parsed_body["valid"]).to be true
      expect(response.parsed_body["products_data"]).to have_key(product.unique_permalink)
    end

    it "returns sold_out error in response when offer code is sold out" do
      offer_code.update_attribute(:max_purchase_count, 0)
      get :compute_discount, params: offer_code_params

      expect(response.parsed_body).to eq({ "error_message" => "Sorry, the discount code you wish to use has reached its usage limit.", "error_code" => "sold_out", "valid" => false })
    end

    context "when the cart is wider than the code's remaining uses" do
      let(:seller) { create(:user) }
      let!(:capped_code) { create(:universal_offer_code, user: seller, amount_cents: 100, max_purchase_count: 2) }
      let(:cart_products) { create_list(:product, 3, user: seller, price_cents: 500) }
      let(:params) do
        {
          code: capped_code.code,
          products: cart_products.to_h { [it.unique_permalink, { permalink: it.unique_permalink, quantity: 1 }] }
        }
      end

      it "discounts the lines that fit and explains why the rest are excluded" do
        get :compute_discount, params: params

        body = response.parsed_body
        expect(body["valid"]).to be true
        expect(body["products_data"].size).to eq(2)
        expect(body["notice"]).to eq("The discount code was applied to some products. The rest exceed its remaining usage limit.")
      end

      it "rejects the whole cart only when no line fits" do
        capped_code.update!(max_purchase_count: 0)
        get :compute_discount, params: params

        expect(response.parsed_body).to eq({
                                             "valid" => false,
                                             "error_code" => "sold_out",
                                             "error_message" => "Sorry, the discount code you wish to use has reached its usage limit.",
                                           })
      end

      it "omits the notice when the code covers the whole cart" do
        capped_code.update!(max_purchase_count: 3)
        get :compute_discount, params: params

        body = response.parsed_body
        expect(body["valid"]).to be true
        expect(body["products_data"].size).to eq(3)
        expect(body).not_to have_key("notice")
      end
    end

    it "doesn't return error in response when offer code discount is greater than the original price of the product but applicable to other product in a bundle" do
      offer_code_amount = product.price_cents + 100
      other_product = create(:product, price_cents: offer_code_amount, user: product.user)
      universal_code = create(:universal_offer_code, amount_cents: offer_code_amount, user: product.user)
      offer_code_params = {
        code: universal_code.code,
        products: {
          other_product.unique_permalink => {
            permalink: other_product.unique_permalink,
            quantity: 2
          }
        }
      }
      get :compute_discount, params: offer_code_params

      expect(response.parsed_body).to eq({
                                           "valid" => true,
                                           "products_data" => {
                                             other_product.unique_permalink => {
                                               "cents" => 600,
                                               "type" => "fixed",
                                               "product_ids" => nil,
                                               "minimum_quantity" => nil,
                                               "expires_at" => nil,
                                               "duration_in_billing_cycles" => nil,
                                               "minimum_amount_cents" => nil,
                                             },
                                           },
                                         })
    end

    it "returns products data" do
      get :compute_discount, params: offer_code_params

      expect(response.parsed_body).to eq({
                                           "valid" => true,
                                           "products_data" => {
                                             product.unique_permalink => {
                                               "type" => "fixed",
                                               "cents" => offer_code.amount,
                                               "product_ids" => [product.external_id],
                                               "minimum_quantity" => nil,
                                               "expires_at" => nil,
                                               "duration_in_billing_cycles" => nil,
                                               "minimum_amount_cents" => nil,
                                             },
                                           },
                                         })
    end

    it "returns an invalid error in response when products param is missing" do
      get :compute_discount, params: { code: offer_code.code }

      expect(response.parsed_body).to eq({ "error_message" => "Sorry, the discount code you wish to use is invalid.", "error_code" => "invalid_offer", "valid" => false })
    end
  end
end
