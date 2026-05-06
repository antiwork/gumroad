require "spec_helper"

RSpec.describe "API::Mobile::Emails create", type: :request do
  before { host! VALID_API_REQUEST_HOSTS.first }

  let(:seller) { create(:user, :eligible_sender) }
  let(:token) { create("doorkeeper/access_token", resource_owner_id: seller.id, scopes: "mobile_api") }
  let(:mobile_token) { Api::Mobile::BaseController::MOBILE_TOKEN }
  let(:auth_headers) { { "Authorization" => "Bearer #{token.token}" } }
  let(:idempotency_key) { SecureRandom.uuid }

  let(:base_payload) do
    {
      installment: {
        name: "Behind the scenes",
        message: "<p>Working on chapter 2.</p>",
        installment_type: "audience",
        shown_on_profile: true,
        send_emails: true,
        allow_comments: true
      },
      publish: true,
      idempotency_key:,
      mobile_token:
    }
  end

  before do
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    allow_any_instance_of(User).to receive(:has_completed_payouts?).and_return(true)
  end

  describe "POST /mobile/emails" do
    it "creates a published installment and returns 200" do
      expect {
        post "/mobile/emails", params: base_payload, headers: auth_headers, as: :json
      }.to change(Installment, :count).by(1)
      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json["success"]).to be true
      expect(json["installment"]["external_id"]).to be_present
      expect(json["installment"]["name"]).to eq("Behind the scenes")
      expect(json["installment"]["installment_type"]).to eq("audience")
    end

    it "is idempotent on retry with the same key" do
      post "/mobile/emails", params: base_payload, headers: auth_headers, as: :json
      first_id = response.parsed_body["installment"]["external_id"]
      expect {
        post "/mobile/emails", params: base_payload, headers: auth_headers, as: :json
      }.not_to change(Installment, :count)
      expect(response.parsed_body["installment"]["external_id"]).to eq first_id
    end

    it "returns 422 for ineligible seller (insufficient sales)" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(0)
      post "/mobile/emails", params: base_payload, headers: auth_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be false
      expect(response.parsed_body["message"]).to include("$100")
    end

    it "returns 401 without OAuth bearer" do
      post "/mobile/emails", params: base_payload, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 400 when idempotency_key is missing" do
      payload = base_payload.except(:idempotency_key)
      post "/mobile/emails", params: payload, headers: auth_headers, as: :json
      expect(response).to have_http_status(:bad_request)
    end

    it "returns 401 with wrong mobile_token" do
      payload = base_payload.merge(mobile_token: "wrong")
      post "/mobile/emails", params: payload, headers: auth_headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 when token lacks mobile_api scope" do
      scoped_token = create("doorkeeper/access_token", resource_owner_id: seller.id, scopes: "creator_api")
      post "/mobile/emails", params: base_payload, headers: { "Authorization" => "Bearer #{scoped_token.token}" }, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 409 when a publish is already in flight for the same key" do
      InstallmentIdempotencyService.reserve(seller_id: seller.id, key: idempotency_key)
      post "/mobile/emails", params: base_payload, headers: auth_headers, as: :json
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["retry_after"]).to eq(5)
    end

    it "persists message HTML byte-exact" do
      html = "<p>Body with <strong>bold</strong> and <em>italics</em></p>"
      payload = base_payload.deep_dup
      payload[:installment][:message] = html
      post "/mobile/emails", params: payload, headers: auth_headers, as: :json
      expect(response).to have_http_status(:ok)
      installment = Installment.find_by_external_id(response.parsed_body["installment"]["external_id"])
      expect(installment.message).to eq(html)
    end

    it "persists shown_on_profile, send_emails, and allow_comments flags" do
      payload = base_payload.deep_dup
      payload[:installment][:shown_on_profile] = false
      payload[:installment][:send_emails] = true
      payload[:installment][:allow_comments] = false
      post "/mobile/emails", params: payload, headers: auth_headers, as: :json
      expect(response).to have_http_status(:ok)
      installment = Installment.find_by_external_id(response.parsed_body["installment"]["external_id"])
      expect(installment.shown_on_profile).to be false
      expect(installment.send_emails).to be true
      expect(installment.allow_comments).to be false
    end

    it "creates a PostEmailBlast and enqueues SendPostBlastEmailsJob when send_emails: true" do
      expect {
        post "/mobile/emails", params: base_payload, headers: auth_headers, as: :json
      }.to change(PostEmailBlast, :count).by(1)
      expect(response).to have_http_status(:ok)
      installment = Installment.find_by_external_id(response.parsed_body["installment"]["external_id"])
      blast = PostEmailBlast.find_by(post: installment)
      expect(blast).to be_present
      expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(blast.id)
    end

    it "does NOT enqueue SendPostBlastEmailsJob when send_emails: false" do
      payload = base_payload.deep_dup
      payload[:installment][:send_emails] = false
      payload[:installment][:shown_on_profile] = true
      expect {
        post "/mobile/emails", params: payload, headers: auth_headers, as: :json
      }.not_to change(PostEmailBlast, :count)
      expect(SendPostBlastEmailsJob).not_to have_enqueued_sidekiq_job
    end
  end
end
