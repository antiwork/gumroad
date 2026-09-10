# frozen_string_literal: true

require "spec_helper"

describe TiktokCallbacksController do
  let(:open_id) { "open-123" }

  describe "POST deauthorize" do
    it "unlinks the live identity but keeps the verification as superseded evidence for every matching Gumroad account" do
      first = create(:social_connect_verification, platform: "tiktok", uid: open_id)
      second = create(:social_connect_verification, platform: "tiktok", uid: open_id)
      other = create(:social_connect_verification, platform: "tiktok")
      first_identity = create(:user_tiktok_identity, user: first.user, tiktok_open_id: open_id)
      other_identity = create(:user_tiktok_identity, user: other.user, tiktok_open_id: other.uid)
      allow_any_instance_of(TiktokWebhook).to receive(:parse).and_return(
        "event" => "authorization.removed",
        "user_openid" => open_id,
      )

      post :deauthorize

      expect(response).to have_http_status(:ok)
      expect(first.reload).to have_attributes(uid: open_id, superseded_at: be_present, currently_linked?: false)
      expect(second.reload.superseded_at).to be_present
      expect(other.reload.superseded_at).to be_nil
      expect(first.shared_identity_user_ids).to eq([second.user_id])
      expect(UserTiktokIdentity.exists?(first_identity.id)).to be(false)
      expect(UserTiktokIdentity.exists?(other_identity.id)).to be(true)
    end

    it "returns 200 without unlinking for a signed non-deauthorize event" do
      verification = create(:social_connect_verification, platform: "tiktok", uid: open_id)
      identity = create(:user_tiktok_identity, user: verification.user, tiktok_open_id: open_id)
      allow_any_instance_of(TiktokWebhook).to receive(:parse).and_return(
        "event" => "video.publish.completed",
        "user_openid" => open_id,
      )

      post :deauthorize

      expect(response).to have_http_status(:ok)
      expect(verification.reload.superseded_at).to be_nil
      expect(UserTiktokIdentity.exists?(identity.id)).to be(true)
    end


    it "returns 400 when a signed payload has string content and no user_openid" do
      secret = "tiktok-client-secret"
      stub_const("TIKTOK_CLIENT_SECRET", secret)
      body = {
        "event" => "authorization.removed",
        "content" => { "open_id" => open_id }.to_json,
      }.to_json
      timestamp = Time.current.to_i.to_s
      digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
      request.headers["TikTok-Signature"] = "t=#{timestamp},s=#{digest}"

      expect {
        post :deauthorize, body:, as: :json
      }.not_to raise_error
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects an invalid signature" do
      allow_any_instance_of(TiktokWebhook).to receive(:parse).and_return(nil)

      post :deauthorize

      expect(response).to have_http_status(:bad_request)
    end
  end
end
