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

    context "when a team admin disconnects the seller's Stripe account" do
      let(:seller) { create(:user) }
      let(:team_admin) { create(:user) }

      before do
        create(:user_compliance_info, user: seller)
        Feature.activate_user(:merchant_migration, seller)
        create(:merchant_account_stripe_connect, user: seller)
        create(:merchant_account_stripe_connect, user: team_admin)
        create(:team_membership, user: team_admin, seller:, role: TeamMembership::ROLE_ADMIN)
        cookies.encrypted[:current_seller_id] = seller.id
        sign_in team_admin
      end

      it "disconnects the seller account and attributes the change to the admin" do
        post :disconnect

        expect(response.parsed_body["success"]).to eq(true)
        expect(seller.reload.stripe_connect_account).to be_nil
        expect(team_admin.reload.stripe_connect_account).to be_present
        expect(seller.comments.last).to have_attributes(
          author_id: team_admin.id,
          content: "Stripe account disconnected by team admin #{team_admin.email}"
        )
      end
    end
  end
end
