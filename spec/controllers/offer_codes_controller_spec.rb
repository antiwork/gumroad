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

    it "returns an error in response when offer code is invalid" do
      offer_code_params[:code] = "invalid_offer"
      get :compute_discount, params: offer_code_params

      expect(response.parsed_body).to eq({ "error_message" => "Sorry, the discount code you wish to use is invalid.", "error_code" => "invalid_offer", "valid" => false })
    end

    it "returns sold_out error in response when offer code is sold out" do
      offer_code.update_attribute(:max_purchase_count, 0)
      get :compute_discount, params: offer_code_params

      expect(response.parsed_body).to eq({ "error_message" => "Sorry, the discount code you wish to use has expired.", "error_code" => "sold_out", "valid" => false })
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

    describe "upgrade discounts" do
      let(:seller) { product.user }
      let(:required_product) { create(:product, user: seller, price_cents: 0) }
      let(:buyer_email) { "buyer@example.com" }

      let(:upgrade_offer_code) do
        create(:offer_code,
               user: seller,
               products: [product],
               amount_cents: nil,
               amount_percentage: 25,
               required_product_ids: [required_product.external_id]
        )
      end

      let(:upgrade_params) do
        {
          code: upgrade_offer_code.code,
          email: buyer_email,
          products: {
            product.unique_permalink => {
              permalink: product.unique_permalink,
              quantity: 1
            }
          }
        }
      end

      before do
        Feature.activate_user(:upgrade_discounts, seller)
      end

      it "returns an error when email is not provided" do
        upgrade_params.delete(:email)
        get :compute_discount, params: upgrade_params

        expect(response.parsed_body).to eq({
                                             "valid" => false,
                                             "error_code" => "missing_email",
                                             "error_message" => "Enter your email to apply this discount."
                                           })
      end

      it "returns an error when buyer does not own the required product" do
        get :compute_discount, params: upgrade_params

        expect(response.parsed_body).to eq({
                                             "valid" => false,
                                             "error_code" => "missing_required_product",
                                             "error_message" => "Sorry, this discount is only available for customers who own a qualifying product."
                                           })
      end

      it "returns the discount when buyer owns the required product" do
        create(:free_purchase, link: required_product, email: buyer_email)

        get :compute_discount, params: upgrade_params

        expect(response.parsed_body["valid"]).to eq(true)
        expect(response.parsed_body["products_data"][product.unique_permalink]["percents"]).to eq(25)
      end
    end
  end
end
