# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Api::Internal::Installments::NonOpenerResendsController do
  let(:seller) { create(:user) }

  include_context "with user signed in as admin for seller"

  let(:product) { create(:product, user: seller, name: "Product one") }
  let(:installment) do
    create(:product_post, :published, seller:, link: product, bought_products: [product.unique_permalink])
  end
  let!(:opened_sale) { create(:purchase, link: product, seller:) }
  let!(:unopened_sale) { create(:purchase, link: product, seller:) }

  before do
    # Original blast: both recipients emailed, only one opened.
    [opened_sale, unopened_sale].each { |sale| SentPostEmail.create!(post: installment, email: sale.email) }
    create(:creator_contacting_customers_email_info_opened, installment: installment, purchase: opened_sale)
    create(:creator_contacting_customers_email_info_sent, installment: installment, purchase: unopened_sale)
  end

  describe "GET show" do
    it_behaves_like "authentication required for action", :get, :show do
      let(:request_params) { { id: installment.external_id } }
    end

    it_behaves_like "authorize called for action", :get, :show do
      let(:record) { installment }
      let(:policy_method) { :resend_to_non_openers? }
      let(:request_params) { { id: installment.external_id } }
    end

    it "returns the number of recipients who have not opened the post yet" do
      get :show, params: { id: installment.external_id }
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "count" => 1, "recently_resent" => false, "audience_filtered_out" => false })
    end

    it "flags audience_filtered_out when unopened recipients exist but are no longer in the audience" do
      not_bought_product = create(:product, user: seller)
      installment.update!(not_bought_products: [product.unique_permalink], bought_products: [not_bought_product.unique_permalink])

      get :show, params: { id: installment.external_id }
      expect(response).to be_successful
      expect(response.parsed_body["count"]).to eq(0)
      expect(response.parsed_body["audience_filtered_out"]).to eq(true)
    end

    it "reports recently_resent when an unopened blast was created within the throttle window" do
      create(:blast, post: installment, recipient_filter: "unopened", requested_at: 1.hour.ago, completed_at: 50.minutes.ago)
      get :show, params: { id: installment.external_id }
      expect(response).to be_successful
      expect(response.parsed_body["recently_resent"]).to eq(true)
    end

    it "returns 404 when the installment is not found" do
      get :show, params: { id: "nonexistent" }
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for a post type that has no per-recipient open tracking (follower)" do
      follower_post = create(:follower_post, :published, seller:)
      get :show, params: { id: follower_post.external_id }
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for an unpublished post" do
      draft = create(:product_post, seller:, link: product, bought_products: [product.unique_permalink])
      get :show, params: { id: draft.external_id }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create" do
    it_behaves_like "authentication required for action", :post, :create do
      let(:request_params) { { id: installment.external_id } }
    end

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { installment }
      let(:policy_method) { :resend_to_non_openers? }
      let(:request_params) { { id: installment.external_id } }
    end

    it "creates an unopened-filtered blast and enqueues the send job" do
      expect do
        post :create, params: { id: installment.external_id }
      end.to change { PostEmailBlast.to_non_openers.where(post: installment).count }.by(1)
        .and change { SendPostBlastEmailsJob.jobs.size }.by(1)

      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "success" => true, "count" => 1 })
    end

    it "returns 422 when everyone who was emailed has already opened" do
      create(:creator_contacting_customers_email_info_opened, installment: installment, purchase: unopened_sale)

      expect do
        post :create, params: { id: installment.external_id }
      end.not_to change { PostEmailBlast.where(post: installment).count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["error"]).to include("already opened")
    end

    it "returns a distinct 422 message when unopened recipients exist but no longer match the audience filter" do
      not_bought_product = create(:product, user: seller)
      installment.update!(not_bought_products: [product.unique_permalink], bought_products: [not_bought_product.unique_permalink])

      expect do
        post :create, params: { id: installment.external_id }
      end.not_to change { PostEmailBlast.where(post: installment).count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("no longer eligible")
    end

    it "throttles a second resend within the window" do
      create(:blast, post: installment, recipient_filter: "unopened", requested_at: 1.hour.ago, completed_at: 1.hour.ago)

      expect do
        post :create, params: { id: installment.external_id }
      end.not_to change { PostEmailBlast.where(post: installment).count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["error"]).to include("once every 24 hours")
    end

    it "allows a resend once the throttle window has passed" do
      create(:blast, post: installment, recipient_filter: "unopened", requested_at: 25.hours.ago, completed_at: 25.hours.ago)

      expect do
        post :create, params: { id: installment.external_id }
      end.to change { PostEmailBlast.to_non_openers.where(post: installment).count }.by(1)

      expect(response).to be_successful
    end

    it "blocks a second resend while a prior one is still in flight" do
      create(:blast, post: installment, recipient_filter: "unopened", requested_at: 5.minutes.ago, started_at: 5.minutes.ago, completed_at: nil)

      expect do
        post :create, params: { id: installment.external_id }
      end.not_to change { PostEmailBlast.where(post: installment).count }

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "blocks a second resend while a prior one is pending (queued but Sidekiq hasn't started it yet)" do
      create(:blast, post: installment, recipient_filter: "unopened", requested_at: 1.minute.ago, started_at: nil, completed_at: nil)

      expect do
        post :create, params: { id: installment.external_id }
      end.not_to change { PostEmailBlast.where(post: installment).count }

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "allows a retry after a failed (never-completed) resend" do
      create(:blast, post: installment, recipient_filter: "unopened", requested_at: 3.hours.ago, started_at: 3.hours.ago, completed_at: nil)

      expect do
        post :create, params: { id: installment.external_id }
      end.to change { PostEmailBlast.to_non_openers.where(post: installment).count }.by(1)

      expect(response).to be_successful
    end

    it "returns 404 when the installment is not found" do
      post :create, params: { id: "nonexistent" }
      expect(response).to have_http_status(:not_found)
    end

    it "blocks a resend once the lifetime cap is reached, even after the throttle window" do
      create_list(:blast, 3, post: installment, recipient_filter: "unopened", requested_at: 25.hours.ago, completed_at: 25.hours.ago)

      expect do
        post :create, params: { id: installment.external_id }
      end.not_to change { PostEmailBlast.where(post: installment).count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["error"]).to include("up to 3 times")
    end

    it "does not count failed (never-completed) prior resends toward the lifetime cap" do
      create_list(:blast, 3, post: installment, recipient_filter: "unopened", requested_at: 25.hours.ago, completed_at: nil, started_at: 25.hours.ago)

      expect do
        post :create, params: { id: installment.external_id }
      end.to change { PostEmailBlast.to_non_openers.where(post: installment).count }.by(1)

      expect(response).to be_successful
    end

    it "does not count zero-delivered resends toward the lifetime cap" do
      create_list(:blast, 3, post: installment, recipient_filter: "unopened", requested_at: 25.hours.ago, started_at: 25.hours.ago, completed_at: 25.hours.ago, delivery_count: 0)

      expect do
        post :create, params: { id: installment.external_id }
      end.to change { PostEmailBlast.to_non_openers.where(post: installment).count }.by(1)

      expect(response).to be_successful
    end

    it "does not let a zero-delivered resend trigger the 24h throttle" do
      create(:blast, post: installment, recipient_filter: "unopened", requested_at: 2.hours.ago, started_at: 2.hours.ago, completed_at: 1.hour.ago, delivery_count: 0)

      expect do
        post :create, params: { id: installment.external_id }
      end.to change { PostEmailBlast.to_non_openers.where(post: installment).count }.by(1)

      expect(response).to be_successful
    end
  end
end
