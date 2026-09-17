# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Products::MarketingAbandonedCartsController do
  include Rails.application.routes.url_helpers

  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:holdout) { false }
  let(:paid) { true }

  include_context "with user signed in as admin for seller"

  before do
    create(:payment_completed, user: seller) if paid
    create(:marketing_holdout_assignment, user: seller, marketing_holdout: holdout)
    Feature.activate_user(:auto_marketing, seller)
  end

  def workflows = seller.workflows.alive.abandoned_cart_type

  describe "#show" do
    it_behaves_like "authorize called for action", :get, :show do
      let(:record) { Marketing::Action }
      let(:policy_klass) { Marketing::ActionPolicy }
      let(:policy_method) { :index? }
      let(:request_params) { { product_id: product.unique_permalink } }
      let(:request_format) { :json }
    end

    it "reports what the email says and when it goes out" do
      get :show, params: { product_id: product.unique_permalink }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "available" => true,
        "enabled" => false,
        "account_wide" => false,
        "subject" => "You left something in your cart",
        "delay_hours" => 24,
        "workflow_url" => nil,
      )
    end

    it "404s when the flag is off" do
      Feature.deactivate_user(:auto_marketing, seller)

      get :show, params: { product_id: product.unique_permalink }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "404s for another seller's product" do
      get :show, params: { product_id: create(:product).unique_permalink }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "404s for an unpublished product" do
      product.update!(draft: true)

      get :show, params: { product_id: product.unique_permalink }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "#update" do
    it_behaves_like "authorize called for action", :put, :update do
      let(:record) { Marketing::Action }
      let(:policy_klass) { Marketing::ActionPolicy }
      let(:policy_method) { :index? }
      let(:request_params) { { product_id: product.unique_permalink } }
      let(:request_format) { :json }
    end

    it "creates and publishes the cart workflow for the product, and records the action once" do
      expect do
        put :update, params: { product_id: product.unique_permalink, enabled: true }, as: :json
      end.to change { workflows.published.count }.from(0).to(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("enabled" => true, "account_wide" => false)

      workflow = workflows.sole
      expect(workflow.bought_products).to eq([product.unique_permalink])
      expect(response.parsed_body["workflow_url"]).to eq(workflow_emails_path(workflow.external_id))

      action = Marketing::Action.where(user: seller, link: product, channel: "abandoned_cart").sole
      expect(action).to be_approved
      expect(action.copy).to end_with("You left something in your cart")
    end

    it "keeps one action row when the seller turns it on again" do
      put :update, params: { product_id: product.unique_permalink, enabled: true }, as: :json
      put :update, params: { product_id: product.unique_permalink, enabled: false }, as: :json

      expect do
        put :update, params: { product_id: product.unique_permalink, enabled: true }, as: :json
      end.not_to change { Marketing::Action.where(link: product).count }
    end

    it "turns it off again without deleting the workflow or its email" do
      put :update, params: { product_id: product.unique_permalink, enabled: true }, as: :json
      workflow = workflows.sole
      installment = workflow.installments.alive.sole

      expect do
        put :update, params: { product_id: product.unique_permalink, enabled: false }, as: :json
      end.to change { workflows.published.count }.from(1).to(0)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("enabled" => false)
      expect(workflow.reload.deleted_at).to be_nil
      expect(installment.reload.deleted_at).to be_nil
    end

    it "does not create a second workflow for a product that already has one" do
      put :update, params: { product_id: product.unique_permalink, enabled: true }, as: :json

      expect do
        put :update, params: { product_id: product.unique_permalink, enabled: true }, as: :json
      end.not_to change { workflows.count }
    end

    it "lets a seller below the email gate turn cart recovery on" do
      put :update, params: { product_id: product.unique_permalink, enabled: true }, as: :json

      expect(seller.reload.eligible_to_send_emails?).to eq(false)
      expect(response).to have_http_status(:ok), "status #{response.status}: #{response.body.to_s[0, 200]}"
      expect(response.parsed_body).to include("enabled" => true)
    end
  end

  context "when the seller has no completed payout" do
    let(:paid) { false }

    it "refuses with the reason instead of creating a workflow" do
      expect do
        put :update, params: { product_id: product.unique_permalink, enabled: true }, as: :json
      end.not_to change { workflows.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Abandoned cart email turns on after your first payout.")
    end

    it "reports the reason on the card" do
      get :show, params: { product_id: product.unique_permalink }, as: :json

      expect(response.parsed_body).to include("available" => false, "enabled" => false)
      expect(response.parsed_body["blocked_reason"]).to be_present
    end
  end

  context "when the seller is held out" do
    let(:holdout) { true }

    before { Feature.activate_percentage(:auto_marketing, 100) }

    it "404s on both endpoints without creating anything" do
      expect do
        get :show, params: { product_id: product.unique_permalink }, as: :json
      end.not_to change { [workflows.count, Marketing::Action.count] }
      expect(response).to have_http_status(:not_found)

      expect do
        put :update, params: { product_id: product.unique_permalink, enabled: true }, as: :json
      end.not_to change { [workflows.count, Marketing::Action.count] }
      expect(response).to have_http_status(:not_found)
    end
  end
end
