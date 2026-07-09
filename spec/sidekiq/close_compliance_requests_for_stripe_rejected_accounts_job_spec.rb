# frozen_string_literal: true

require "spec_helper"

describe CloseComplianceRequestsForStripeRejectedAccountsJob do
  describe "#perform" do
    it "closes open verification requests for users whose Stripe account was rejected" do
      rejected_user = create(:user)
      create(:merchant_account, user: rejected_user, stripe_disabled_reason: "rejected.fraud")
      rejected_request = create(:user_compliance_info_request, user: rejected_user, field_needed: UserComplianceInfoFields::Individual::TAX_ID)

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
  end
end
