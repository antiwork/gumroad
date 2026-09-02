# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe ConnectionsController do
  let(:seller) { create(:named_seller) }

  before :each do
    sign_in seller
  end

  it_behaves_like "authorize called for controller", Settings::ProfilePolicy do
    let(:record) { :profile }
    let(:policy_method) { :manage_social_connections? }
  end

  describe "POST unlink_twitter" do
    before do
      seller.twitter_user_id = "123"
      seller.twitter_handle = "gumroad"
      seller.save!
    end

    it "unsets all twitter properties" do
      post :unlink_twitter

      seller.reload
      User::SocialTwitter::TWITTER_PROPERTIES.each do |property|
        expect(seller.attributes[property]).to be(nil)
      end

      expect(response.body).to eq({ success: true }.to_json)
    end

    it "keeps the social connect verification row while clearing the live twitter identity" do
      verification = create(:social_connect_verification, user: seller, platform: "twitter", uid: "123", handle: "gumroad")

      post :unlink_twitter

      expect(response.body).to eq({ success: true }.to_json)
      expect(seller.reload.twitter_user_id).to be_nil
      expect(SocialConnectVerification.exists?(id: verification.id)).to be(true)
      expect(verification.reload.uid).to eq("123")
    end

    it "responds with an error message if the unlink fails" do
      allow_any_instance_of(User).to receive(:save!).and_raise("Failed to unlink Twitter")

      post :unlink_twitter

      expect(response.body).to eq({ success: false, error_message: "Failed to unlink Twitter" }.to_json)
    end
  end

  describe "POST unlink_youtube" do
    before do
      seller.update!(youtube_channel_id: "UC123", youtube_handle: "creator")
    end

    it "clears the live youtube identity and keeps the verification row" do
      verification = create(:social_connect_verification, user: seller, platform: "youtube", uid: "UC123", handle: "creator")

      post :unlink_youtube

      expect(response.body).to eq({ success: true }.to_json)
      expect(seller.reload.youtube_channel_id).to be_nil
      expect(seller.youtube_handle).to be_nil
      expect(SocialConnectVerification.exists?(id: verification.id)).to be(true)
    end
  end
end
