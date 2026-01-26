# frozen_string_literal: true

describe SuspendAccountsWithPaymentAddressWorker do
  describe "#perform" do
    before do
      @suspended_user = create(:user, user_risk_state: "suspended_for_fraud", payment_address: "sameuser@paypal.com")
    end

    it "suspends other accounts with the same payment address" do
      @user_2 = create(:user, payment_address: "sameuser@paypal.com")

      described_class.new.perform(@suspended_user.id)

      expect(@user_2.reload.suspended?).to be(true)
      expect(@user_2.comments.first.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of payment address #{@suspended_user.payment_address} (from User##{@suspended_user.id})")
      expect(@user_2.comments.last.content).to eq("Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of payment address #{@suspended_user.payment_address} (from User##{@suspended_user.id})")
      expect(@user_2.comments.first.author_name).to eq(SuspendAccountsWithPaymentAddressWorker::SUSPEND_ACCOUNTS_WITH_PAYMENT_ADDRESS_AUTHOR_NAME)
      expect(@user_2.comments.last.author_name).to eq(SuspendAccountsWithPaymentAddressWorker::SUSPEND_ACCOUNTS_WITH_PAYMENT_ADDRESS_AUTHOR_NAME)
    end

    it "does not suspend already suspended users or verified users" do
      suspended_fraud_seller = create(:user, payment_address: "sameuser@paypal.com", user_risk_state: "suspended_for_fraud")
      suspended_tos_seller = create(:user, payment_address: "sameuser@paypal.com", user_risk_state: "suspended_for_tos_violation")
      verified_seller = create(:user, payment_address: "sameuser@paypal.com", verified: true, user_risk_state: "compliant")

      described_class.new.perform(@suspended_user.id)

      expect(suspended_fraud_seller.reload.suspended_for_fraud?).to be(true)
      expect(suspended_tos_seller.reload.suspended_for_tos_violation?).to be(true)
      expect(verified_seller.reload.compliant?).to be(true)

      expect(suspended_fraud_seller.comments.count).to eq(0)
      expect(suspended_tos_seller.comments.count).to eq(0)
      expect(verified_seller.comments.count).to eq(0)
    end

    it "does nothing if payment_address is blank" do
      suspended_seller_no_payment = create(:user, user_risk_state: "suspended_for_fraud", payment_address: nil)
      compliant_seller = create(:user, payment_address: "sameuser@paypal.com", user_risk_state: "compliant")

      described_class.new.perform(suspended_seller_no_payment.id)

      expect(compliant_seller.reload.suspended?).to be(false)
    end

    it "raises error if user is not in suspended_for_fraud state" do
      compliant_seller = create(:user, user_risk_state: "compliant", payment_address: "sameuser@paypal.com")

      expect do
        described_class.new.perform(compliant_seller.id)
      end.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
