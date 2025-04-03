# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Api::Internal::Installments::AudienceCountsController do
  let(:seller) { create(:user) }

  include_context "with user signed in as admin for seller"

  describe "GET show" do
    let(:product1) { create(:product, user: seller) }
    let(:product1_variant) { create(:variant, variant_category: create(:variant_category, link: product1)) }
    let(:product2) { create(:product, user: seller) }
    let!(:product1_variant_purchase1) { create(:purchase, seller:, link: product1, email: "john@example.com", country: "United States", variant_attributes: [product1_variant]) }
    let!(:product1_purchase2) { create(:purchase, seller:, link: product1, email: "jane@example.com", country: "United States") }
    let!(:product2_purchase) { create(:purchase, seller:, link: product2, email: "bob@example.com", country: "Canada") }
    let!(:active_follower1) { create(:active_follower, user: seller) }
    let!(:active_follower2) { create(:active_follower, user: seller) }
    let!(:affiliate1) { create(:direct_affiliate, seller:, send_posts: true) { |affiliate| affiliate.products << product1 } }

    it_behaves_like "authentication required for action", :get, :show do
      let(:request_params) { { id: create(:installment).external_id } }
    end

    it_behaves_like "authorize called for action", :get, :show do
      let(:record) { create(:installment, seller:) }
      let(:policy_method) { :updated_audience_count? }
      let(:request_params) { { id: record.external_id } }
    end

    it "returns audience count" do
      get :show, params: { id: create(:audience_post, seller:).external_id }
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "count" => 6 })

      get :show, params: { id: create(:seller_post, seller:).external_id }
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "count" => 3 })

      get :show, params: { id: create(:product_post, seller:, link: product1, bought_products: [product1.unique_permalink]).external_id }
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "count" => 2 })

      get :show, params: { id: create(:variant_post, link: product1, base_variant: product1_variant, bought_variants: [product1_variant.external_id]).external_id }
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "count" => 1 })

      get :show, params: { id: create(:follower_post, seller:).external_id }
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "count" => 2 })

      get :show, params: { id: create(:affiliate_post, seller:, affiliate_products: [product1.unique_permalink]).external_id }
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "count" => 1 })
    end
  end
end
