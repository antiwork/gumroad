# frozen_string_literal: true

require "spec_helper"

describe UpdateUserCountry do
  before do
    @user = create(:named_user)
    create(:ach_account_stripe_succeed, user: @user)
    create(:ach_account, user: @user)
    create(:user_compliance_info, user: @user)
    create(:merchant_account, user: @user, charge_processor_id: StripeChargeProcessor.charge_processor_id)
  end

  describe "#process" do
    it "deletes the old compliance info and creates a new one" do
      old_compliance_info = @user.alive_user_compliance_info
      UpdateUserCountry.new(new_country_code: "GB", user: @user).process

      expect(old_compliance_info.reload.deleted?).to eq(true)
    end

    it "deletes the old stripe account" do
      old_stripe_account = @user.stripe_account
      UpdateUserCountry.new(new_country_code: "GB", user: @user).process

      expect(old_stripe_account.reload.deleted?).to eq(true)
    end

    it "marks all pending compliance info requests as provided" do
      create(:user_compliance_info_request, user: @user, field_needed: UserComplianceInfoFields::Individual::TAX_ID)
      create(:user_compliance_info_request, user: @user, field_needed: UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID)
      create(:user_compliance_info_request, user: @user, field_needed: UserComplianceInfoFields::Business::STRIPE_COMPANY_DOCUMENT_ID)

      expect(@user.user_compliance_info_requests.provided.count).to eq(0)
      expect(@user.user_compliance_info_requests.requested.count).to eq(3)

      UpdateUserCountry.new(new_country_code: "GB", user: @user).process

      expect(@user.user_compliance_info_requests.provided.count).to eq(3)
      expect(@user.user_compliance_info_requests.requested.count).to eq(0)
    end

    it "deletes the old bank account" do
      old_bank_account = @user.active_bank_account
      UpdateUserCountry.new(new_country_code: "GB", user: @user).process

      expect(old_bank_account.reload.deleted?).to eq(true)
    end

    it "adds country changed comment" do
      UpdateUserCountry.new(new_country_code: "GB", user: @user).process

      comment = @user.reload.comments.last
      expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_COUNTRY_CHANGED)
      expect(comment.content).to eq("Country changed from US to GB")
    end

    context "when old and new country are not Stripe-supported countries" do
      it "retains PayPal payment address" do
        payment_address = @user.payment_address
        allow(@user).to receive(:native_payouts_supported?).and_return(false)

        UpdateUserCountry.new(new_country_code: "GB", user: @user).process

        expect(@user.reload.payment_address).to eq(payment_address)
      end
    end

    context "when user has balance" do
      before do
        stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id) # For negative credits
        @merchant_account = create(:merchant_account, user: @user)
        create(:balance, merchant_account: @merchant_account, user: @user, amount_cents: 1000, state: "unpaid")
      end

      it "marks balances as forfeited" do
        UpdateUserCountry.new(new_country_code: "GB", user: @user).process

        expect(@user.reload.balances.last.state).to eq("forfeited")
        expect(@user.reload.balances.last.merchant_account).to eq(@merchant_account)
      end

      it "adds comment on the user" do
        UpdateUserCountry.new(new_country_code: "GB", user: @user).process

        comment = @user.reload.comments.last
        expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_BALANCE_FORFEITED)
        expect(comment.content).to eq("Balance of $10 has been forfeited. Reason: Country changed. Balance IDs: #{Balance.last.id}")
      end
    end
  end
end
