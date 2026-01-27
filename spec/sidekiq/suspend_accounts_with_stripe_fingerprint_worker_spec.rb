# frozen_string_literal: true

describe SuspendAccountsWithStripeFingerprintWorker do
  describe "#perform" do
    let(:fingerprint) { SecureRandom.hex(16) }

    before do
      @suspended_user = create(:user, user_risk_state: "suspended_for_fraud")
      create(:ach_account, user: @suspended_user, stripe_fingerprint: fingerprint)
    end

    it "suspends other accounts with the same Stripe fingerprint" do
      @user_2 = create(:user)
      @user_3 = create(:user)
      create(:ach_account, user: @user_2, stripe_fingerprint: fingerprint)
      create(:ach_account, user: @user_3, stripe_fingerprint: SecureRandom.hex(16))

      described_class.new.perform(@suspended_user.id)

      expect(@user_2.reload.suspended?).to be(true)
      expect(@user_3.reload.suspended?).to be(false)
      expect(@user_2.comments.first.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{fingerprint} (from User##{@suspended_user.id})")
      expect(@user_2.comments.last.content).to eq("Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{fingerprint} (from User##{@suspended_user.id})")
      expect(@user_2.comments.first.author_name).to eq(User::Risk::SUSPEND_SELLERS_OTHER_ACCOUNTS_AUTHOR_NAME)
      expect(@user_2.comments.last.author_name).to eq(User::Risk::SUSPEND_SELLERS_OTHER_ACCOUNTS_AUTHOR_NAME)
    end

    it "does not suspend already suspended users or verified users" do
      suspended_fraud_seller = create(:user, user_risk_state: "suspended_for_fraud")
      suspended_tos_seller = create(:user, user_risk_state: "suspended_for_tos_violation")
      verified_seller = create(:user, verified: true, user_risk_state: "compliant")
      create(:ach_account, user: suspended_fraud_seller, stripe_fingerprint: fingerprint)
      create(:ach_account, user: suspended_tos_seller, stripe_fingerprint: fingerprint)
      create(:ach_account, user: verified_seller, stripe_fingerprint: fingerprint)

      described_class.new.perform(@suspended_user.id)

      expect(suspended_fraud_seller.reload.suspended_for_fraud?).to be(true)
      expect(suspended_tos_seller.reload.suspended_for_tos_violation?).to be(true)
      expect(verified_seller.reload.compliant?).to be(true)

      expect(suspended_fraud_seller.comments.count).to eq(0)
      expect(suspended_tos_seller.comments.count).to eq(0)
      expect(verified_seller.comments.count).to eq(0)
    end

    it "does nothing if suspended user has no Stripe fingerprints" do
      suspended_seller_no_fingerprint = create(:user, user_risk_state: "suspended_for_fraud")
      compliant_seller = create(:user, user_risk_state: "compliant")
      create(:ach_account, user: compliant_seller, stripe_fingerprint: fingerprint)

      described_class.new.perform(suspended_seller_no_fingerprint.id)

      expect(compliant_seller.reload.suspended?).to be(false)
    end

    it "raises error if user is not in suspended_for_fraud state" do
      compliant_seller = create(:user, user_risk_state: "compliant")
      create(:ach_account, user: compliant_seller, stripe_fingerprint: fingerprint)

      expect do
        described_class.new.perform(compliant_seller.id)
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "suspends other sellers sharing the fraud fingerprint, when suspended seller updated their only matching bank account to evade detection" do
      suspended_user = create(:user, user_risk_state: "suspended_for_fraud")
      previous_account = create(:ach_account, user: suspended_user, stripe_fingerprint: fingerprint)
      previous_account.mark_deleted!
      create(:ach_account, user: suspended_user, stripe_fingerprint: SecureRandom.hex(16))
      user_to_suspend = create(:user)
      create(:ach_account, user: user_to_suspend, stripe_fingerprint: fingerprint)

      described_class.new.perform(suspended_user.id)

      expect(user_to_suspend.reload.suspended?).to be(true)
      expect(user_to_suspend.comments.first.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{fingerprint} (from User##{suspended_user.id})")
      expect(user_to_suspend.comments.last.content).to eq("Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{fingerprint} (from User##{suspended_user.id})")
      expect(user_to_suspend.comments.first.author_name).to eq(User::Risk::SUSPEND_SELLERS_OTHER_ACCOUNTS_AUTHOR_NAME)
      expect(user_to_suspend.comments.last.author_name).to eq(User::Risk::SUSPEND_SELLERS_OTHER_ACCOUNTS_AUTHOR_NAME)
    end
  end
end
