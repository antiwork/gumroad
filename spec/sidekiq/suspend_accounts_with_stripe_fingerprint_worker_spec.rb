# frozen_string_literal: true

describe SuspendAccountsWithStripeFingerprintWorker do
  describe "#perform" do
    let(:fingerprint) { SecureRandom.hex(16) }

    before do
      @user = create(:user)
      @user_2 = create(:user)
      @user_3 = create(:user)
      create(:ach_account, user: @user, stripe_fingerprint: fingerprint)
      create(:ach_account, user: @user_2, stripe_fingerprint: fingerprint)
      create(:ach_account, user: @user_3, stripe_fingerprint: SecureRandom.hex(16))
    end

    it "suspends other accounts with the same Stripe fingerprint" do
      described_class.new.perform(@user.id)

      expect(@user_2.reload.suspended?).to be(true)
      expect(@user_3.reload.suspended?).to be(false)
      expect(@user_2.comments.first.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{fingerprint} (from User##{@user.id})")
      expect(@user_2.comments.last.content).to eq("Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{fingerprint} (from User##{@user.id})")
    end
  end
end
