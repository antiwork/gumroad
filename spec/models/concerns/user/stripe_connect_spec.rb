# frozen_string_literal: true

require "spec_helper"

describe User::StripeConnect do
  describe ".find_or_create_for_stripe_connect_account" do
    before do
      @data = {
        "provider" => "stripe_connect",
        "uid" => "acct_1MbJuNSAp3rt4s0F",
        "info" => {
          "name" => "Gum Bot",
          "email" => "bot@gum.co",
          "nickname" => "gumbot",
          "scope" => "read_write",
          "livemode" => false },
        "extra" => {
          "extra_info" => {
            "id" => "acct_1MbJuNSAp3rt4s0F",
            "object" => "account",
            "country" => "IN",
            "created" => 1676363450,
            "default_currency" => "inr"
          }
        }
      }
    end

    it "returns the user associated with the Stripe Connect account if one exists" do
      creator = create(:user)
      create(:merchant_account_stripe_connect, user: creator, charge_processor_merchant_id: @data["uid"])

      expect(User.find_or_create_for_stripe_connect_account(@data)).to eq(creator)
    end

    it "does not return the user associated with the email and does not create a new one as email is already taken" do
      create(:user, email: @data["info"]["email"])

      expect do
        expect do
          expect(User.find_or_create_for_stripe_connect_account(@data)).to be nil
        end.not_to change { User.count }
      end.not_to change { UserComplianceInfo.count }
    end

    it "creates a new user account and sets email and country" do
      expect do
        expect do
          User.find_or_create_for_stripe_connect_account(@data)
        end.to change { User.count }.by(1)
      end.to change { UserComplianceInfo.count }.by(1)

      expect(User.last.email).to eq(@data["info"]["email"])
      expect(User.last.alive_user_compliance_info.country).to eq(Compliance::Countries.mapping[@data["extra"]["extra_info"]["country"]])
      expect(User.last.confirmed?).to be true
    end

    it "associates past purchases with the same email to the new user" do
      email = @data["info"]["email"]
      purchase1 = create(:purchase, email:)
      purchase2 = create(:purchase, email:)
      expect(purchase1.purchaser_id).to be_nil
      expect(purchase2.purchaser_id).to be_nil

      user = User.find_or_create_for_stripe_connect_account(@data)

      expect(user.email).to eq("bot@gum.co")
      expect(purchase1.reload.purchaser_id).to eq(user.id)
      expect(purchase2.reload.purchaser_id).to eq(user.id)
    end
  end

  describe "#has_brazilian_stripe_connect_account?" do
    let(:user) { create(:user_compliance_info).user }

    it "returns true if user has a Brazilian Stripe Connect merchant account" do
      merchant_account = create(:merchant_account_stripe_connect, user:, country: Compliance::Countries::BRA.alpha2)
      allow(user).to receive(:merchant_account).with(StripeChargeProcessor.charge_processor_id).and_return(merchant_account)

      expect(user.has_brazilian_stripe_connect_account?).to be true
    end

    it "returns false if user has a non-Brazilian Stripe Connect merchant account" do
      merchant_account = create(:merchant_account_stripe_connect, user:, country: Compliance::Countries::USA.alpha2)
      allow(user).to receive(:merchant_account).with(StripeChargeProcessor.charge_processor_id).and_return(merchant_account)

      expect(user.has_brazilian_stripe_connect_account?).to be false
    end

    it "returns false if user has no Stripe Connect merchant account" do
      expect(user.has_brazilian_stripe_connect_account?).to be false
    end
  end
end
