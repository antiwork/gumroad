# frozen_string_literal: true

require "spec_helper"

describe Api::V2::MarketingActionsController do
  let(:seller) { create(:named_seller, twitter_handle: "seller", twitter_oauth_token: "tok", twitter_oauth_secret: "sec") }
  let(:product) { create(:product, user: seller) }
  let(:token) { create("doorkeeper/access_token", resource_owner_id: seller.id, scopes: "edit_emails") }
  let(:action) { create(:marketing_action, user: seller, link: product) }
  let(:member_params) { { access_token: token.token, id: action.external_id, idempotency_key: action.api_idempotency_key, confirmation_token: action.confirmation_token } }

  let(:holdout) { false }

  before do
    create(:marketing_holdout_assignment, user: seller, marketing_holdout: holdout)
    Feature.activate_user(:auto_marketing, seller)
  end

  describe "eligibility" do
    let(:holdout) { true }

    it "refuses a holdout seller on every endpoint" do
      get :recommendations, params: { access_token: token.token, product_id: product.external_id }
      expect(response).to have_http_status(:not_found)

      post :create, params: { access_token: token.token, product_id: product.external_id, channel: "x" }
      expect(response).to have_http_status(:not_found)

      post :approve, params: member_params
      expect(response).to have_http_status(:not_found)
      expect(action.reload).to be_recommended
      expect(WebMock).not_to have_requested(:post, Marketing::XApi::TWEETS_URL)
    end
  end

  describe "recommendations and creation" do
    it "returns the existing recommendation, tagged link, and opaque idempotency key" do
      params = { access_token: token.token, product_id: product.external_id }
      get :recommendations, params: params
      entry = response.parsed_body.fetch("channels").first
      expect(entry).to include("channel" => "x", "handle" => "seller", "live" => true)
      expect(entry.fetch("action")).to include("status" => "recommended", "idempotency_key" => match(/\A[0-9a-f]{64}\z/))
      expect(entry.dig("action", "link_url")).to be_present

      expect do
        post :create, params: params.merge(channel: "x")
      end.not_to change { [Marketing::Action.count, UtmLink.count] }
      expect(response.parsed_body.fetch("marketing_action")).to eq(entry.fetch("action"))
    end

    it "keeps the recommendation account and token together across reconnect during serialization" do
      expected_token = nil
      allow_any_instance_of(Marketing::Recommendations).to receive(:call).and_wrap_original do |original|
        entries = original.call
        expected_token = entries.first.fetch(:action).confirmation_token
        User.find(seller.id).update!(twitter_handle: "reconnected")
        entries
      end

      get :recommendations, params: { access_token: token.token, product_id: product.external_id }
      entry = response.parsed_body.fetch("channels").first
      expect(entry.fetch("handle")).to eq("seller")
      expect(entry.dig("action", "confirmation_token")).to eq(expected_token)
      recommended_action = Marketing::Action.find_by_external_id(entry.dig("action", "id"))
      original = recommended_action.attributes

      post :approve, params: { access_token: token.token, id: entry.dig("action", "id"),
                               idempotency_key: entry.dig("action", "idempotency_key"),
                               confirmation_token: entry.dig("action", "confirmation_token") }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(recommended_action.reload.attributes).to eq(original)
      expect(WebMock).not_to have_requested(:post, Marketing::XApi::TWEETS_URL)
    end

    [nil, "", "unknown"].each do |channel|
      it "rejects #{channel.inspect} channel without creating records" do
        params = { access_token: token.token, product_id: product.external_id }
        params[:channel] = channel unless channel.nil?
        expect { post :create, params: params }.not_to change { [Marketing::Action.count, UtmLink.count] }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq("success" => false, "message" => "Unknown marketing channel.")
      end
    end

    it "accepts a product permalink" do
      get :recommendations, params: { access_token: token.token, product_id: product.unique_permalink }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("channels").first.fetch("action")).to be_present
    end

    %i[recommendations create].each do |operation|
      it "rejects a draft on #{operation} without creating marketing records" do
        product.update!(draft: true)
        expect do
          process operation, method: operation == :create ? :post : :get, params: { access_token: token.token, product_id: product.external_id, channel: "x" }
        end.not_to change { [Marketing::Action.count, UtmLink.count] }
        expect(response).to have_http_status(:not_found)
      end

      it "rejects another seller's product on #{operation}" do
        other = create(:product)
        process operation, method: operation == :create ? :post : :get, params: { access_token: token.token, product_id: other.external_id, channel: "x" }
        expect(response).to have_http_status(:not_found)
      end
    end

    it "does not create actions for unavailable channels" do
      post :create, params: { access_token: token.token, product_id: product.external_id, channel: "instagram" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(Marketing::Action.count).to eq(0)
    end
  end

  %i[recommendations create show approve execute cancel].each do |operation|
    describe operation.to_s do
      let(:params) { member_params.merge(product_id: product.external_id, channel: "x") }
      let(:method) { %i[recommendations show].include?(operation) ? :get : :post }

      it "returns 404 with the flag off" do
        Feature.deactivate_user(:auto_marketing, seller)
        process operation, method:, params: params
        expect(response).to have_http_status(:not_found)
        expect(action.reload).to be_recommended
      end

      it "rejects a token without the emails write scope" do
        token.update!(scopes: "edit_products")
        process operation, method:, params: params
        expect(response).to have_http_status(:forbidden)
      end

      it "rejects missing authentication" do
        process operation, method:, params: params.except(:access_token)
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  %i[show approve execute cancel].each do |operation|
    it "cannot #{operation} another seller's action" do
      other = create(:marketing_action)
      process operation, method: operation == :show ? :get : :post, params: member_params.merge(id: other.external_id, idempotency_key: other.api_idempotency_key)
      expect(response).to have_http_status(:not_found)
      expect(other.reload).to be_recommended
    end

    it "cannot #{operation} an action whose product changed owners" do
      product.update!(user: create(:user))
      process operation, method: operation == :show ? :get : :post, params: member_params
      expect(response).to have_http_status(:not_found)
    end
  end

  %i[approve execute cancel].each do |operation|
    it "rejects an incorrect idempotency key for #{operation}" do
      post operation, params: member_params.merge(idempotency_key: "wrong")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(action.reload).to be_recommended
    end
  end

  it "double approves and executes the same action without a second post" do
    request = WebMock.stub_request(:post, Marketing::XApi::TWEETS_URL).to_return(status: 201, body: { data: { id: "123" } }.to_json, headers: { "Content-Type" => "application/json" })
    get :show, params: member_params
    key = response.parsed_body.fetch("marketing_action").fetch("idempotency_key")
    params = member_params.merge(idempotency_key: key)

    2.times do
      post :approve, params: params
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("marketing_action")).to include("id" => action.external_id, "idempotency_key" => key)
      post :execute, params: params
      expect(response.parsed_body.fetch("marketing_action")).to include("status" => "posted", "id" => action.external_id)
    end
    expect(Marketing::Action.count).to eq(1)
    expect(request).to have_been_requested.once
  end

  %i[approve execute].each do |operation|
    [[], ["token"], { value: "token" }, "", " "].each do |invalid_token|
      it "rejects #{invalid_token.inspect} confirmation token for #{operation} without changing state" do
        action.approve! if operation == :execute
        original = action.attributes
        post operation, params: member_params.merge(confirmation_token: invalid_token, copy: "Unapproved change"), as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq("success" => false, "message" => "Review the action and supply its confirmation_token.")
        expect(action.reload.attributes).to eq(original)
        expect(WebMock).not_to have_requested(:post, Marketing::XApi::TWEETS_URL)
      end
    end

    it "rejects a missing confirmation token for #{operation}" do
      post operation, params: member_params.except(:confirmation_token)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(action.reload).to be_recommended
    end

    it "rejects changed copy after the preview for #{operation}" do
      action.approve! if operation == :execute
      params = member_params
      action.update!(copy: "Changed in another client")
      post operation, params: params
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("message")).to include("Review it and confirm again")
      expect(WebMock).not_to have_requested(:post, Marketing::XApi::TWEETS_URL)
    end

    it "rejects a changed account after the preview for #{operation}" do
      action.approve! if operation == :execute
      params = member_params
      seller.update!(twitter_handle: "different")
      post operation, params: params
      expect(response).to have_http_status(:unprocessable_entity)
      expect(WebMock).not_to have_requested(:post, Marketing::XApi::TWEETS_URL)
    end
  end

  it "does not replace the approved account token after reconnect before serialization" do
    params = member_params.merge(copy: "Reviewed edit")
    expected_token = nil
    allow_any_instance_of(Marketing::Action).to receive(:approve_copy).and_wrap_original do |original, **attributes|
      outcome = original.call(**attributes)
      expected_token = original.receiver.confirmation_token
      User.find(seller.id).update!(twitter_handle: "reconnected")
      outcome
    end

    post :approve, params: params
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.fetch("handle")).to eq("seller")
    expect(body.dig("marketing_action", "confirmation_token")).to eq(expected_token)
    expect(body.dig("marketing_action", "copy")).to eq("Reviewed edit")
    original = action.reload.attributes

    post :execute, params: params.merge(confirmation_token: body.dig("marketing_action", "confirmation_token"))
    expect(response).to have_http_status(:unprocessable_entity)
    expect(action.reload.attributes).to eq(original)
    expect(WebMock).not_to have_requested(:post, Marketing::XApi::TWEETS_URL)
  end

  it "does not execute without approval" do
    post :execute, params: member_params
    expect(action.reload).to be_recommended
    expect(response.parsed_body.dig("marketing_action", "error_code")).to eq("not_approved")
    expect(WebMock).not_to have_requested(:post, Marketing::XApi::TWEETS_URL)
  end

  it "validates edited copy and preserves the original" do
    original = action.copy
    post :approve, params: member_params.merge(copy: "x" * 300)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(action.reload.copy).to eq(original)
    post :approve, params: member_params.merge(copy: "Edited")
    expect(action.reload.copy).to eq("Edited")
  end

  it "returns the reconnect fallback from the existing executor" do
    action.approve!
    WebMock.stub_request(:post, Marketing::XApi::TWEETS_URL).to_return(status: 403, body: "{}")
    post :execute, params: member_params
    expect(response.parsed_body.dig("marketing_action", "error_code")).to eq("x_write_permission_missing")
    expect(response.parsed_body.fetch("intent_url")).to include("twitter.com/intent/tweet")
  end

  it "cancels idempotently but cannot cancel a claimed post" do
    2.times do
      post :cancel, params: member_params
      expect(response).to have_http_status(:ok)
      expect(action.reload).to be_cancelled
    end
    action.update!(status: "queued", queued_at: Time.current)
    post :cancel, params: member_params
    expect(response).to have_http_status(:unprocessable_entity)
    expect(action.reload).to be_queued
  end

  %i[approve cancel].each do |operation|
    it "rejects #{operation} on a cart receipt without changing its workflow or history" do
      create(:payment_completed, user: seller)
      workflow = Marketing::AbandonedCart.new(product:, seller:).enable
      receipt = create(:marketing_action, user: seller, link: product, channel: "abandoned_cart", status: "approved")
      original = receipt.attributes
      post operation, params: { access_token: token.token, id: receipt.external_id, idempotency_key: receipt.api_idempotency_key, confirmation_token: receipt.confirmation_token, copy: "Different receipt text" }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to include("Workflows")
      expect(receipt.reload.attributes).to eq(original)
      expect(workflow.reload.published_at).to be_present
    end
  end
end
