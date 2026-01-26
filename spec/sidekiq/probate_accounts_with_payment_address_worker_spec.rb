# frozen_string_literal: true

describe ProbateAccountsWithPaymentAddressWorker do
  describe "#perform" do
    before do
      @suspended_user = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: "tos@example.com")
    end

    it "probates compliant, not_reviewed, and verified users with the same payment address" do
      compliant_seller = create(:user, payment_address: "tos@example.com", user_risk_state: "compliant")
      not_reviewed_seller = create(:user, payment_address: "tos@example.com", user_risk_state: "not_reviewed")
      verified_seller = create(:user, payment_address: "tos@example.com", verified: true, user_risk_state: "compliant")

      described_class.new.perform(@suspended_user.id)

      expect(compliant_seller.reload.on_probation?).to be(true)
      expect(not_reviewed_seller.reload.on_probation?).to be(true)
      expect(verified_seller.reload.on_probation?).to be(true)

      comment = compliant_seller.comments.last
      expect(comment.author_name).to eq(ProbateAccountsWithPaymentAddressWorker::PROBATE_ACCOUNTS_WITH_PAYMENT_ADDRESS_AUTHOR_NAME)
      expect(comment.content).to eq("Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of payment address tos@example.com (from suspended for TOS violation User##{@suspended_user.id})")
    end

    it "does not probate users who are not compliant or not_reviewed" do
      on_probation_seller = create(:user, payment_address: "tos@example.com", user_risk_state: "on_probation")
      flagged_fraud_seller = create(:user, payment_address: "tos@example.com", user_risk_state: "flagged_for_fraud")
      flagged_tos_seller = create(:user, payment_address: "tos@example.com", user_risk_state: "flagged_for_tos_violation")
      suspended_fraud_seller = create(:user, payment_address: "tos@example.com", user_risk_state: "suspended_for_fraud")
      suspended_tos_seller = create(:user, payment_address: "tos@example.com", user_risk_state: "suspended_for_tos_violation")

      described_class.new.perform(@suspended_user.id)

      expect(on_probation_seller.comments.count).to eq(0)
      expect(on_probation_seller.reload.on_probation?).to be(true)
      expect(flagged_fraud_seller.reload.on_probation?).to be(false)
      expect(flagged_tos_seller.reload.on_probation?).to be(false)
      expect(suspended_fraud_seller.reload.on_probation?).to be(false)
      expect(suspended_tos_seller.reload.on_probation?).to be(false)
    end

    it "does nothing if payment_address is blank" do
      suspended_user_no_payment = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: nil)
      user = create(:user, payment_address: "tos@example.com", user_risk_state: "compliant")

      described_class.new.perform(suspended_user_no_payment.id)

      expect(user.reload.on_probation?).to be(false)
    end
  end
end
