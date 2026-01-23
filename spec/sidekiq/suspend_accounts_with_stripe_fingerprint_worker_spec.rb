# frozen_string_literal: true

describe SuspendAccountsWithStripeFingerprintWorker do
  describe "#perform" do
    let(:stripe_fingerprint) { "acct_fingerprint_123" }

    it "suspends other accounts with the same bank account fingerprint" do
      user_1 = create(:user)
      create(:ach_account, user: user_1, stripe_fingerprint: stripe_fingerprint)

      user_2 = create(:user)
      create(:ach_account, user: user_2, stripe_fingerprint: stripe_fingerprint)

      described_class.new.perform(user_1.id)

      expect(user_2.reload.suspended?).to be(true)
      expect(user_2.comments.first.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of bank account fingerprint from User##{user_1.id}")
      expect(user_2.comments.last.content).to eq("Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of bank account fingerprint from User##{user_1.id}")
    end

    it "does not suspend the user who was originally suspended" do
      user_1 = create(:user)
      create(:ach_account, user: user_1, stripe_fingerprint: stripe_fingerprint)

      user_2 = create(:user)
      create(:ach_account, user: user_2, stripe_fingerprint: stripe_fingerprint)

      described_class.new.perform(user_1.id)

      expect(user_1.reload.suspended?).to be(false)
    end

    it "does nothing if the user has no bank account" do
      user_1 = create(:user)
      user_2 = create(:user)
      create(:ach_account, user: user_2, stripe_fingerprint: stripe_fingerprint)

      expect { described_class.new.perform(user_1.id) }.not_to raise_error
      expect(user_2.reload.suspended?).to be(false)
    end

    it "does nothing if the bank account has no fingerprint" do
      user_1 = create(:user)
      create(:ach_account, user: user_1, stripe_fingerprint: nil)

      user_2 = create(:user)
      create(:ach_account, user: user_2, stripe_fingerprint: nil)

      described_class.new.perform(user_1.id)

      expect(user_2.reload.suspended?).to be(false)
    end

    it "ignores deleted bank accounts when suspending other accounts" do
      user_1 = create(:user)
      create(:ach_account, user: user_1, stripe_fingerprint: stripe_fingerprint)

      user_2 = create(:user)
      bank_account_2 = create(:ach_account, user: user_2, stripe_fingerprint: stripe_fingerprint)
      bank_account_2.mark_deleted!

      described_class.new.perform(user_1.id)

      expect(user_2.reload.suspended?).to be(false)
    end

    it "suspends multiple accounts with the same fingerprint" do
      user_1 = create(:user)
      create(:ach_account, user: user_1, stripe_fingerprint: stripe_fingerprint)

      user_2 = create(:user)
      create(:ach_account, user: user_2, stripe_fingerprint: stripe_fingerprint)

      user_3 = create(:user)
      create(:ach_account, user: user_3, stripe_fingerprint: stripe_fingerprint)

      described_class.new.perform(user_1.id)

      expect(user_2.reload.suspended?).to be(true)
      expect(user_3.reload.suspended?).to be(true)
    end

    it "raises RecordNotFound when the user does not exist" do
      expect { described_class.new.perform(999999999) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "skips already suspended accounts" do
      user_1 = create(:user)
      create(:ach_account, user: user_1, stripe_fingerprint: stripe_fingerprint)

      user_2 = create(:user, user_risk_state: "suspended_for_fraud")
      create(:ach_account, user: user_2, stripe_fingerprint: stripe_fingerprint)

      user_3 = create(:user)
      create(:ach_account, user: user_3, stripe_fingerprint: stripe_fingerprint)

      described_class.new.perform(user_1.id)

      expect(user_2.reload.user_risk_state).to eq("suspended_for_fraud")
      expect(user_3.reload.suspended?).to be(true)
    end

    it "suspends users who are already flagged for fraud" do
      user_1 = create(:user)
      create(:ach_account, user: user_1, stripe_fingerprint: stripe_fingerprint)

      user_2 = create(:user, user_risk_state: "flagged_for_fraud")
      create(:ach_account, user: user_2, stripe_fingerprint: stripe_fingerprint)

      described_class.new.perform(user_1.id)

      expect(user_2.reload.suspended_for_fraud?).to be(true)
    end

    it "does not trigger cascading suspensions due to skip_transition_callback" do
      user_1 = create(:user)
      create(:ach_account, user: user_1, stripe_fingerprint: stripe_fingerprint)

      user_2 = create(:user)
      create(:ach_account, user: user_2, stripe_fingerprint: stripe_fingerprint)

      expect(SuspendAccountsWithStripeFingerprintWorker).not_to receive(:perform_in)
      expect(SuspendAccountsWithPaymentAddressWorker).not_to receive(:perform_in)

      described_class.new.perform(user_1.id)
    end
  end
end
