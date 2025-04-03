# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Api::Internal::Installments::RecipientCountsController do
  let(:seller) { create(:user) }

  include_context "with user signed in as admin for seller"

  describe "GET show" do
    let(:product1) { create(:product, user: seller) }
    let(:product1_variant) { create(:variant, variant_category: create(:variant_category, link: product1)) }
    let(:product2) { create(:product, user: seller) }
    let!(:product1_variant_purchase1) { create(:purchase, seller:, link: product1, email: "john@example.com", country: "United States", variant_attributes: [product1_variant], created_at: Time.current) }
    let!(:product1_purchase2) { create(:purchase, seller:, link: product1, email: "jane@example.com", country: "United States", created_at: 1.week.ago) }
    let!(:product1_purchase3) { create(:purchase, seller:, link: product1, email: "foo@example.com", country: "Canada", created_at: 2.weeks.ago) }
    let!(:product2_purchas1) { create(:purchase, seller:, link: product2, email: "jane@example.com", country: "United States", created_at: Time.current) }
    let!(:product2_purchase2) { create(:purchase, seller:, link: product2, email: "foo@example.com", country: "Canada", created_at: 2.weeks.ago) }
    let!(:active_follower1) { create(:active_follower, user: seller, created_at: Time.current) }
    let!(:active_follower2) { create(:active_follower, user: seller, created_at: 1.week.ago, confirmed_at: 1.week.ago) }

    it_behaves_like "authentication required for action", :get, :show do
      let(:request_params) { { installment_type: "audience" } }
    end

    it_behaves_like "authorize called for action", :get, :show do
      let(:record) { Installment }
      let(:policy_method) { :updated_recipient_count? }
      let(:request_params) { { installment_type: "audience" } }
    end

    it "returns counts for audience installment type" do
      get :show, params: { installment_type: "audience" }
      expect(response).to be_successful
      expect(response.parsed_body).to eq("recipient_count" => 5, "audience_count" => 5)
    end

    it "returns counts for seller installment type" do
      get :show, params: { installment_type: "seller" }
      expect(response).to be_successful
      expect(response.parsed_body).to eq("recipient_count" => 3, "audience_count" => 5)
    end

    it "returns counts for product installment type" do
      get :show, params: { installment_type: "product", link_id: product1.unique_permalink }
      expect(response).to be_successful
      expect(response.parsed_body).to eq("recipient_count" => 3, "audience_count" => 5)
    end

    it "returns counts for follower installment type" do
      get :show, params: { installment_type: "follower" }
      expect(response).to be_successful
      expect(response.parsed_body).to eq("recipient_count" => 2, "audience_count" => 5)
    end

    it "returns counts for audience installment type with created_after filter" do
      get :show, params: { installment_type: "audience", created_after: 10.days.ago.to_s }
      expect(response).to be_successful
      expect(response.parsed_body).to eq("recipient_count" => 4, "audience_count" => 5)
    end

    it "returns counts for audience installment type with created_before filter" do
      get :show, params: { installment_type: "audience", created_before: 5.days.ago.to_s }
      expect(response).to be_successful
      expect(response.parsed_body).to eq("recipient_count" => 3, "audience_count" => 5)
    end

    it "returns counts for seller installment type with paid_more_than_cents filter" do
      product1_purchase2.update!(price_cents: 99)
      product1_purchase3.update!(price_cents: 500)
      product2_purchas1.update!(price_cents: 999)
      AudienceMember.refresh_all!(seller:)
      get :show, params: { installment_type: "seller", paid_more_than_cents: 100 }
      expect(response).to be_successful
      expect(response.parsed_body).to eq("recipient_count" => 2, "audience_count" => 5)
    end

    it "returns counts for seller installment type with paid_less_than_cents filter" do
      product1_purchase2.update!(price_cents: 999)
      product1_purchase3.update!(price_cents: 1500)
      product2_purchas1.update!(price_cents: 2000)
      AudienceMember.refresh_all!(seller:)
      get :show, params: { installment_type: "seller", paid_less_than_cents: 1000 }
      expect(response).to be_successful
      expect(response.parsed_body).to eq("recipient_count" => 3, "audience_count" => 5)
    end

    it "returns counts for seller installment type with bought_products filter" do
      get :show, params: { installment_type: "seller", bought_products: [product2.unique_permalink] }
      expect(response).to be_successful
      expect(response.parsed_body).to eq("recipient_count" => 2, "audience_count" => 5)
    end

    it "returns counts for audience installment type with not_bought_products filter" do
      get :show, params: { installment_type: "audience", not_bought_products: [product2.unique_permalink] }
      expect(response).to be_successful
      expect(response.parsed_body).to eq("recipient_count" => 3, "audience_count" => 5)
    end

    it "returns counts for seller installment type with bought_variants filter" do
      get :show, params: { installment_type: "seller", bought_variants: [product1_variant.external_id] }
      expect(response).to be_successful
      expect(response.parsed_body).to eq("recipient_count" => 1, "audience_count" => 5)
    end

    it "returns counts for audience installment type with not_bought_variants filter" do
      get :show, params: { installment_type: "audience", not_bought_variants: [product1_variant.external_id] }
      expect(response).to be_successful
      expect(response.parsed_body).to eq("recipient_count" => 4, "audience_count" => 5)
    end

    it "returns counts for seller installment type with bought_from filter" do
      get :show, params: { installment_type: "seller", bought_from: "Canada" }
      expect(response).to be_successful
      expect(response.parsed_body).to eq("recipient_count" => 1, "audience_count" => 5)
    end
  end
end
