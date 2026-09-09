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
      allow_any_instance_of(TiktokWebhook).to receive(:parse).and_return("user_openid" => open_id)

      post :deauthorize

      expect(response).to have_http_status(:ok)
      expect(first.reload).to have_attributes(uid: open_id, superseded_at: be_present, currently_linked?: false)
      expect(second.reload.superseded_at).to be_present
      expect(other.reload.superseded_at).to be_nil
      expect(first.shared_identity_user_ids).to eq([second.user_id])
      expect(UserTiktokIdentity.exists?(first_identity.id)).to be(false)
      expect(UserTiktokIdentity.exists?(other_identity.id)).to be(true)
    end

    it "rejects an invalid signature" do
      allow_any_instance_of(TiktokWebhook).to receive(:parse).and_return(nil)

      post :deauthorize

      expect(response).to have_http_status(:bad_request)
    end
  end
end
