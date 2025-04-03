# frozen_string_literal: true

require "spec_helper"

describe Settings::StripeController, :vcr do
  describe "POST disconnect" do
    before do
      @creator = create(:user)
      create(:user_compliance_info, user: @creator)

      Feature.activate_user(:merchant_migration, @creator)
      create(:merchant_account_stripe_connect, user: @creator)
      expect(@creator.stripe_connect_account).to be_present
      expect(@creator.has_stripe_account_connected?).to be true

      sign_in @creator
    end

    context "when stripe disconnect is allowed" do
      it "marks the connected Stripe merchant account as deleted" do
        expect_any_instance_of(User).to receive(:stripe_disconnect_allowed?).once.and_return true

        post :disconnect

        expect(response.parsed_body["success"]).to eq(true)
        expect(@creator.stripe_connect_account).to be nil
        expect(@creator.has_stripe_account_connected?).to be false
      end

      it "reactivates creator's old gumroad-controlled Stripe account associated with their unpaid balance" do
        stripe_account = create(:merchant_account_stripe_canada, user: @creator)
        stripe_account.delete_charge_processor_account!
        create(:balance, user: @creator, merchant_account: stripe_account)
        expect(@creator.stripe_account).to be nil
        expect_any_instance_of(User).to receive(:stripe_disconnect_allowed?).once.and_return true

        post :disconnect

        expect(response.parsed_body["success"]).to eq(true)
        expect(@creator.has_stripe_account_connected?).to be false
        expect(@creator.stripe_connect_account).to be nil
        expect(@creator.stripe_account).to eq stripe_account
      end

      it "reactivates creator's old gumroad-controlled Stripe account that's associated with the active bank account" do
        stripe_account = create(:merchant_account_stripe_canada, user: @creator)
        stripe_account.delete_charge_processor_account!
        create(:ach_account, user: @creator, stripe_connect_account_id: stripe_account.charge_processor_merchant_id)
        expect(@creator.stripe_account).to be nil
        expect_any_instance_of(User).to receive(:stripe_disconnect_allowed?).once.and_return true

        post :disconnect

        expect(response.parsed_body["success"]).to eq(true)
        expect(@creator.has_stripe_account_connected?).to be false
        expect(@creator.stripe_connect_account).to be nil
        expect(@creator.stripe_account).to eq stripe_account
      end
    end
  end
end
