# frozen_string_literal: true

require "spec_helper"

describe CloseComplianceRequestsForStripeRejectedAccountsJob do
  describe "#perform" do
    def stub_stripe_account(merchant_account, requirements: {}, future_requirements: {})
      allow(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id).and_return(
        Stripe::Account.construct_from(
          id: merchant_account.charge_processor_merchant_id,
          object: "account",
          requirements: { "currently_due" => [], "past_due" => [], "eventually_due" => [] }.merge(requirements),
          future_requirements: { "currently_due" => [] }.merge(future_requirements)
        )
      )
    end

    it "closes open verification requests for users whose Stripe account was terminally rejected" do
      rejected_user = create(:user)
      rejected_ma = create(:merchant_account, user: rejected_user, stripe_disabled_reason: "rejected.fraud")
      rejected_request = create(:user_compliance_info_request, user: rejected_user, field_needed: UserComplianceInfoFields::Individual::TAX_ID)
      stub_stripe_account(rejected_ma)

      active_user = create(:user)
      create(:merchant_account, user: active_user, stripe_disabled_reason: "requirements.past_due")
      active_request = create(:user_compliance_info_request, user: active_user, field_needed: UserComplianceInfoFields::Individual::TAX_ID)

      no_stripe_user = create(:user)
      no_stripe_request = create(:user_compliance_info_request, user: no_stripe_user, field_needed: UserComplianceInfoFields::Individual::TAX_ID)

      described_class.new.perform

      expect(rejected_request.reload.state).to eq("provided")
      expect(active_request.reload.state).to eq("requested")
      expect(no_stripe_request.reload.state).to eq("requested")
    end

    it "leaves requests open for rejected accounts that still have open Stripe requirements (appealable fork)" do
      # e.g. Japan `rejected.listed` collision: rejected, but Stripe still has
      # a live identity-document request open — the seller can still appeal.
      appealable_user = create(:user)
      appealable_ma = create(:merchant_account, user: appealable_user, stripe_disabled_reason: "rejected.listed")
      appealable_request = create(:user_compliance_info_request, user: appealable_user, field_needed: UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID)
      stub_stripe_account(appealable_ma, requirements: { "past_due" => ["individual.verification.document"] })

      described_class.new.perform

      expect(appealable_request.reload.state).to eq("requested")
    end

    it "leaves requests open when the Stripe lookup fails rather than guessing" do
      rejected_user = create(:user)
      merchant_account = create(:merchant_account, user: rejected_user, stripe_disabled_reason: "rejected.fraud")
      request = create(:user_compliance_info_request, user: rejected_user, field_needed: UserComplianceInfoFields::Individual::TAX_ID)
      allow(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id)
        .and_raise(Stripe::APIConnectionError.new("timeout"))

      expect do
        described_class.new.perform
      end.not_to raise_error

      expect(request.reload.state).to eq("requested")
    end
  end
end
