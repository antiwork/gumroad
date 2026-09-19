# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Products::MarketingActionsController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller, twitter_handle: "seller", twitter_oauth_token: "tok", twitter_oauth_secret: "sec") }
  let(:product) { create(:product, user: seller) }
  let(:holdout) { false }

  include_context "with user signed in as admin for seller"

  before do
    create(:marketing_holdout_assignment, user: seller, marketing_holdout: holdout)
    Feature.activate_user(:auto_marketing, seller)
  end

  describe "#index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Marketing::Action }
      let(:policy_klass) { Marketing::ActionPolicy }
      let(:request_params) { { product_id: product.unique_permalink } }
      let(:request_format) { :json }
    end

    it "returns the channel picker with an X action" do
      get :index, params: { product_id: product.unique_permalink }, as: :json

      expect(response).to have_http_status(:ok)
      channels = response.parsed_body["channels"]
      expect(channels.map { _1["channel"] }).to eq(%w[x instagram youtube tiktok email])
      expect(channels.first).to include("live" => true, "connected" => true, "handle" => "seller")
      expect(channels.first["action"]).to include("status" => "recommended")
      expect(channels.second).to include("live" => false)
    end

    it "404s when the flag is off" do
      Feature.deactivate_user(:auto_marketing, seller)
      get :index, params: { product_id: product.unique_permalink }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "404s instead of failing the request when the flag read stalls" do
      allow(Flipper).to receive(:enabled?).with(:auto_marketing, seller).and_raise(Redis::TimeoutError.new("Waited 1.0 seconds"))

      expect do
        get :index, params: { product_id: product.unique_permalink }, as: :json
      end.not_to change { [Marketing::Action.count, UtmLink.count] }

      expect(response).to have_http_status(:not_found)
    end

    it "404s for another seller's product" do
      get :index, params: { product_id: create(:product).unique_permalink }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "404s for an unpublished product without creating an action or a launch link" do
      product.update!(draft: true)

      expect do
        get :index, params: { product_id: product.unique_permalink }, as: :json
      end.not_to change { [Marketing::Action.count, UtmLink.where(utm_campaign: "launch").count] }

      expect(response).to have_http_status(:not_found)
    end

    context "when the seller can send emails" do
      before do
        create(:payment_completed, user: seller)
        allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
      end

      it "prepares one launch email draft and reports what it would reach" do
        expect do
          get :index, params: { product_id: product.unique_permalink }, as: :json
        end.to change { seller.installments.alive.count }.by(1)

        email = response.parsed_body["channels"].find { _1["channel"] == "email" }
        expect(email).to include("eligible" => true, "blocked_reason" => nil)
        expect(email["counts"]).to eq("customers" => 0, "followers" => 0, "affiliates" => 0, "total" => 0)
        expect(email["draft"]).to include("subject" => product.name, "state" => "draft")
        # The action's channel is read back off the row, so this proves what was persisted.
        expect(email["action"]).to include("channel" => "email")

        draft = Installment.find_by_external_id(email["draft"]["id"])
        expect(draft).to have_attributes(installment_type: Installment::AUDIENCE_TYPE,
                                         not_bought_products: [product.unique_permalink],
                                         published_at: nil)
        expect(draft.ready_to_publish?).to eq(false)
        expect(SendPostBlastEmailsJob.jobs).to be_empty
        expect(PostEmailBlast.count).to eq(0)
      end
    end

    it "reports the gate reason and drafts nothing for a seller who cannot email yet" do
      expect do
        get :index, params: { product_id: product.unique_permalink }, as: :json
      end.not_to change { Installment.count }

      email = response.parsed_body["channels"].find { _1["channel"] == "email" }
      expect(email).to include("eligible" => false, "draft" => nil)
      expect(email["blocked_reason"]).to be_present
      expect(email["action"]).to include("status" => "blocked", "error_code" => "email_eligibility_not_met")
    end
  end

  context "when the seller is held out" do
    let(:holdout) { true }

    before { Feature.activate_percentage(:auto_marketing, 100) }

    it "404s on recommendations without creating marketing records" do
      expect do
        get :index, params: { product_id: product.unique_permalink }, as: :json
      end.not_to change { [Marketing::Action.count, UtmLink.count] }
      expect(response).to have_http_status(:not_found)
    end

    %i[show approve execute cancel].each do |endpoint|
      it "404s on #{endpoint} without changing an existing action or sending a post" do
        action = create(:marketing_action, user: seller, link: product, status: "approved", approved_at: Time.current)
        original = action.attributes
        public_send(endpoint == :show ? :get : :post, endpoint, params: { product_id: product.unique_permalink, id: action.external_id }, as: :json)

        expect(response).to have_http_status(:not_found)
        expect(action.reload.attributes).to eq(original)
        expect(WebMock).not_to have_requested(:post, Marketing::XApi::TWEETS_URL)
      end
    end
  end

  describe "member actions" do
    let!(:action) { create(:marketing_action, user: seller, link: product, copy: "Original") }

    it_behaves_like "authorize called for action", :post, :approve do
      let(:record) { action }
      let(:request_params) { { product_id: product.unique_permalink, id: action.external_id } }
      let(:request_format) { :json }
    end

    it "approves with edited copy" do
      post :approve, params: { product_id: product.unique_permalink, id: action.external_id, copy: "Edited" }, as: :json
      expect(response).to have_http_status(:ok)
      expect(action.reload).to be_approved
      expect(action.copy).to eq("Edited")
    end

    it "rejects over-length copy" do
      post :approve, params: { product_id: product.unique_permalink, id: action.external_id, copy: "a" * 300 }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(action.reload.copy).to eq("Original")
    end

    it "executes through the channel executor and returns the fallback" do
      action.approve!
      WebMock.stub_request(:post, Marketing::XApi::TWEETS_URL).to_return(status: 403, body: "{}", headers: { "Content-Type" => "application/json" })

      post :execute, params: { product_id: product.unique_permalink, id: action.external_id }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["action"]).to include("status" => "approved", "error_code" => "x_write_permission_missing")
      expect(response.parsed_body["intent_url"]).to include("twitter.com/intent/tweet")
      expect(action.reload).not_to be_terminal
    end

    it "cancels an open action" do
      post :cancel, params: { product_id: product.unique_permalink, id: action.external_id }, as: :json
      expect(action.reload).to be_cancelled
    end

    it "refuses to cancel an action the executor has claimed" do
      action.update!(status: "queued", queued_at: Time.current)

      post :cancel, params: { product_id: product.unique_permalink, id: action.external_id }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(action.reload).to be_queued
    end

    it "keeps a claimed action's copy frozen and still lets the client resolve the attempt" do
      action.update!(status: "queued", queued_at: 10.minutes.ago)

      post :approve, params: { product_id: product.unique_permalink, id: action.external_id, copy: "Edited" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(action.reload).to be_queued
      expect(action.copy).to eq("Original")

      post :execute, params: { product_id: product.unique_permalink, id: action.external_id }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["action"]).to include("status" => "failed", "error_code" => "x_post_result_unknown")
      expect(WebMock).not_to have_requested(:post, Marketing::XApi::TWEETS_URL)
    end

    it "refuses to execute an action on a channel that is not a posting channel" do
      cart_action = create(:marketing_action, user: seller, link: product, channel: "abandoned_cart", copy: "Cart reminder")
      cart_action.approve!

      post :execute, params: { product_id: product.unique_permalink, id: cart_action.external_id }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(cart_action.reload).to be_approved
    end

    it "forbids another seller's team" do
      other_product = create(:product)
      other_action = create(:marketing_action, user: other_product.user, link: other_product, copy: "x")
      post :approve, params: { product_id: other_product.unique_permalink, id: other_action.external_id }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(other_action.reload).to be_recommended
    end

    it "404s when the flag is off" do
      Feature.deactivate_user(:auto_marketing, seller)
      get :show, params: { product_id: product.unique_permalink, id: action.external_id }, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
  describe "email execution" do
    let(:action) { create(:marketing_action, user: seller, link: product, channel: "email") }
    let(:email_params) { { product_id: product.unique_permalink, id: action.external_id } }

    before do
      create(:payment_completed, user: seller)
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    end

    it "returns the same draft edit URL on retries without sending" do
      2.times do
        post :execute, params: email_params, as: :json
        expect(response).to have_http_status(:ok)
        draft = seller.installments.sole
        expect(response.parsed_body).to include("edit_url" => edit_email_path(draft.external_id), "intent_url" => nil, "connect_path" => nil)
        expect(draft).to have_attributes(published_at: nil, ready_to_publish: false)
      end
      expect(PostEmailBlast.count).to eq(0)
      expect(SendPostBlastEmailsJob.jobs.size).to eq(0)
    end

    %w[cancelled unpublished].each do |state|
      it "rejects a #{state} email action without preparing a draft" do
        params = email_params
        state == "cancelled" ? action.cancel! : product.update!(draft: true)

        expect { post :execute, params:, as: :json }.not_to change(Installment, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to include("success" => false, "error" => "This launch email is no longer available.")
        expect(SendPostBlastEmailsJob.jobs.size).to eq(0)
      end
    end

    context "when held out" do
      let(:holdout) { true }

      it "refuses a held-out seller without creating a draft" do
        expect { post :execute, params: email_params, as: :json }.not_to change(Installment, :count)
        expect(response).to have_http_status(:not_found)
      end
    end

    it "refuses when the feature is disabled without creating a draft" do
      Feature.deactivate_user(:auto_marketing, seller)
      expect { post :execute, params: email_params, as: :json }.not_to change(Installment, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "keeps the email eligibility gate" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(0)
      expect { post :execute, params: email_params, as: :json }.not_to change(Installment, :count)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("edit_url" => nil)
    end
  end

  %i[approve cancel].each do |operation|
    it "rejects #{operation} on a cart receipt without changing its workflow or history" do
      create(:payment_completed, user: seller)
      workflow = Marketing::AbandonedCart.new(product:, seller:).enable
      receipt = create(:marketing_action, user: seller, link: product, channel: "abandoned_cart", status: "approved")
      original = receipt.attributes
      post operation, params: { product_id: product.unique_permalink, id: receipt.external_id, copy: "Different receipt text" }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Workflows")
      expect(receipt.reload.attributes).to eq(original)
      expect(workflow.reload.published_at).to be_present
    end
  end
end
