# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/sellers_base_controller_concern"

describe AffiliateRequests::OnboardingFormController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }
  let(:published_product_one) { create(:product, user: seller) }
  let(:published_product_two) { create(:product, user: seller) }
  let!(:published_product_three) { create(:product, user: seller) }
  let(:unpublished_product) { create(:product, user: seller, purchase_disabled_at: DateTime.current) }
  let!(:published_collab_product) { create(:product, :is_collab, user: seller) }
  let!(:deleted_product) { create(:product, user: seller, deleted_at: DateTime.current) }
  let!(:enabled_self_service_affiliate_product_for_published_product_one) { create(:self_service_affiliate_product, enabled: true, seller:, product: published_product_one, affiliate_basis_points: 1000) }
  let!(:enabled_self_service_affiliate_product_for_published_product_two) { create(:self_service_affiliate_product, enabled: true, seller:, product: published_product_two, destination_url: "https://example.com") }
  let!(:enabled_self_service_affiliate_product_for_collab_product) do
    create(:self_service_affiliate_product, enabled: true, seller:).tap do
      _1.product.update!(is_collab: true) # bypass `product_is_not_a_collab` validation
    end
  end
  let(:self_service_collab_product) { enabled_self_service_affiliate_product_for_collab_product.product }

  include_context "with user signed in as admin for seller"

  describe "PATCH update" do
    it_behaves_like "authorize called for action", :patch, :update do
      let(:record) { :onboarding_form }
      let(:policy_klass) { AffiliateRequests::OnboardingFormPolicy }
    end

    context "when the request payload contains invalid information" do
      context "such as an invalid fee percent" do
        let(:params) do
          {
            products: [
              { id: published_product_one.external_id_numeric, enabled: true, name: published_product_one.name, fee_percent: 500, destination_url: nil }
            ]
          }
        end

        it "responds with an error without persisting any changes" do
          expect do
            patch :update, params:, format: :json
          end.to_not change { seller.self_service_affiliate_products.reload }

          expect(response.parsed_body["success"]).to eq false
          expect(response.parsed_body["error"]).to eq "Validation failed: Affiliate commission must be between 1% and 75%."
        end
      end

      context "such as an ineligible product" do
        let(:params) do
          {
            products: [
              { id: published_collab_product.external_id_numeric, enabled: true, name: published_collab_product.name, fee_percent: 40, destination_url: nil }
            ]
          }
        end

        it "responds with an error without persisting any changes" do
          expect do
            patch :update, params:, format: :json
          end.to_not change { seller.self_service_affiliate_products.reload }

          expect(response.parsed_body["success"]).to eq false
          expect(response.parsed_body["error"]).to eq "Validation failed: Collab products cannot have affiliates"
        end
      end
    end

    context "when the request payload is valid" do
      let(:params) do
        {
          products: [
            { id: published_product_one.external_id_numeric, enabled: false, name: published_product_one.name, fee_percent: 10, destination_url: nil },
            { id: published_product_two.external_id_numeric, enabled: false, fee_percent: 5, destination_url: "https://example.com" },
            { id: published_product_three.external_id_numeric, enabled: true, name: published_product_three.name, fee_percent: 25, destination_url: "https://example.com/test" },
            { id: self_service_collab_product.external_id_numeric, enabled: false, name: self_service_collab_product.name, fee_percent: 10 },
            { id: "12345", enabled: true, name: "A product", fee_percent: 10, destination_url: nil }
          ],
          disable_global_affiliate: true
        }
      end

      it "upserts the self service affiliate products, ignoring ineligible products and updates the global affiliate status" do
        expect do
          patch :update, params:, format: :json
          seller.reload
        end.to change { seller.self_service_affiliate_products.count }.from(3).to(4)
           .and change { seller.self_service_affiliate_products.enabled.count }.from(3).to(1)
           .and change { seller.disable_global_affiliate }.from(false).to(true)

        expect(response.parsed_body["success"]).to eq(true)
        expect(enabled_self_service_affiliate_product_for_published_product_one.reload.enabled).to eq(false)
        expect(enabled_self_service_affiliate_product_for_published_product_two.reload.enabled).to eq(false)
        expect(enabled_self_service_affiliate_product_for_published_product_two.destination_url).to eq("https://example.com")
        expect(enabled_self_service_affiliate_product_for_collab_product.reload.enabled).to eq(false)
        expect(seller.self_service_affiliate_products.last.slice(:product_id, :affiliate_basis_points, :destination_url)).to eq(
          "product_id" => published_product_three.id,
          "affiliate_basis_points" => 2500,
          "destination_url" => "https://example.com/test"
        )
      end

      context "when a pending affiliate request exists and all products are being disabled" do
        let!(:pending_affiliate_request) { create(:affiliate_request, seller:) }

        let(:params) do
          {
            products: [
              { id: published_product_one.external_id_numeric, enabled: false, fee_percent: 10 },
              { id: published_product_two.external_id_numeric, enabled: false, fee_percent: 5 },
              { id: published_product_three.external_id_numeric, enabled: false, fee_percent: 25 },
              { id: "12345", enabled: true, fee_percent: 10 }
            ]
          }
        end

        it "responds with an error and does not persist the requested changes" do
          expect do
            expect do
              patch :update, params:, as: :json
            end.to_not change { seller.self_service_affiliate_products.count }
          end.to_not change { seller.self_service_affiliate_products.enabled.count }

          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["error"]).to eq("You need to have at least one product enabled since there are some pending affiliate requests")
        end
      end
    end
  end
end
