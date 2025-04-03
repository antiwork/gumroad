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

    it "responds with an error message if the unlink fails" do
      allow_any_instance_of(User).to receive(:save!).and_raise("Failed to unlink Twitter")

      post :unlink_twitter

      expect(response.body).to eq({ success: false, error_message: "Failed to unlink Twitter" }.to_json)
    end
  end
end
