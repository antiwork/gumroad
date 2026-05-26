# frozen_string_literal: true

require "spec_helper"

describe ProfilePresenter do
  describe "#profile_settings_props" do
    let(:request) { ActionDispatch::TestRequest.create }

    def create_seller!(username:, email:)
      seller = User.new(
        username:,
        email:,
        password: "-42Q_.c_3628Ca!mW-xTJ8v*",
        confirmed_at: Time.current,
        user_risk_state: "not_reviewed",
        payment_address: email,
        current_sign_in_ip: "127.0.0.1",
        last_sign_in_ip: "127.0.0.1",
        account_created_ip: "127.0.0.1",
        pre_signup_affiliate_request_processed: true
      )
      seller.skip_enabling_two_factor_authentication = true
      seller.save!
      seller
    end

    def profile_settings_for(seller)
      described_class.new(pundit_user: SellerContext.new(user: seller, seller:), seller:)
                     .profile_settings_props(request:)[:profile_settings]
    end

    it "renders the persisted username, not the fallback username" do
      seller = create_seller!(username: "tommygkendrick", email: "tx-actor@example.com")

      allow(seller).to receive(:username).and_return("txactorexamplecom")

      expect(profile_settings_for(seller)[:username]).to eq("tommygkendrick")
    end

    it "renders an empty string when the username is nil" do
      seller = create_seller!(username: nil, email: "foo@example.com")

      expect(profile_settings_for(seller)[:username]).to eq("")
    end
  end
end
