# frozen_string_literal: true

require "spec_helper"

describe InstagramCallbacksController do
  let(:signed_request) { instance_double(InstagramSignedRequest) }
  let(:instagram_user_id) { "17841400000000000" }

  before do
    allow(InstagramSignedRequest).to receive(:new).and_return(signed_request)
    allow(signed_request).to receive(:parse).with("signed-request").and_return(
      "algorithm" => "HMAC-SHA256",
      "user_id" => instagram_user_id,
    )
  end

  describe "POST deauthorize" do
    it "deletes stored Instagram data for every matching Gumroad account" do
      first = create(:social_connect_verification, platform: "instagram", uid: instagram_user_id)
      second = create(:social_connect_verification, platform: "instagram", uid: instagram_user_id)
      other = create(:social_connect_verification, platform: "instagram")
      first_identity = create(:user_instagram_identity, user: first.user, instagram_user_id: instagram_user_id)
      other_identity = create(:user_instagram_identity, user: other.user, instagram_user_id: other.uid)

      post :deauthorize, params: { signed_request: "signed-request" }

      expect(response).to have_http_status(:ok)
      expect(SocialConnectVerification.where(id: [first.id, second.id])).to be_empty
      expect(SocialConnectVerification.exists?(other.id)).to be(true)
      expect(UserInstagramIdentity.exists?(first_identity.id)).to be(false)
      expect(UserInstagramIdentity.exists?(other_identity.id)).to be(true)
    end

    it "rejects an invalid signed request" do
      allow(signed_request).to receive(:parse).and_return(nil)

      post :deauthorize, params: { signed_request: "signed-request" }

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "POST data_deletion" do
    it "deletes the data and returns a status URL with a confirmation code" do
      verification = create(:social_connect_verification, platform: "instagram", uid: instagram_user_id)
      allow(signed_request).to receive(:confirmation_code).with(instagram_user_id).and_return("a" * 48)

      post :data_deletion, params: { signed_request: "signed-request" }

      expect(response).to have_http_status(:ok)
      expect(SocialConnectVerification.exists?(verification.id)).to be(false)
      expect(response.parsed_body["url"]).to end_with("/instagram/data_deletion/#{'a' * 48}")
      expect(response.parsed_body["confirmation_code"]).to eq("a" * 48)
    end
  end

  describe "GET data_deletion_status" do
    it "shows a completed status for a valid confirmation code" do
      allow(signed_request).to receive(:valid_confirmation_code?).with("a" * 48).and_return(true)

      get :data_deletion_status, params: { confirmation_code: "a" * 48 }

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("Instagram data deletion completed.")
    end

    it "rejects malformed confirmation codes" do
      allow(signed_request).to receive(:valid_confirmation_code?).with("invalid").and_return(false)

      get :data_deletion_status, params: { confirmation_code: "invalid" }

      expect(response).to have_http_status(:not_found)
    end
  end
end
