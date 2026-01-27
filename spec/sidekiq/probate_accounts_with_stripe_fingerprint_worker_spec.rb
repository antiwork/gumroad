# frozen_string_literal: true

describe ProbateAccountsWithStripeFingerprintWorker do
  describe "#perform" do
    let(:tos_fingerprint) { SecureRandom.hex(16) }

    before do
      @suspended_user = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: nil)
      create(:ach_account, user: @suspended_user, stripe_fingerprint: tos_fingerprint)
    end

    it "probates compliant, not_reviewed, and verified users with the same Stripe fingerprint" do
      compliant_seller = create(:user, payment_address: nil, user_risk_state: "compliant")
      create(:ach_account, user: compliant_seller, stripe_fingerprint: tos_fingerprint)
      not_reviewed_seller = create(:user, payment_address: nil, user_risk_state: "not_reviewed")
      create(:ach_account, user: not_reviewed_seller, stripe_fingerprint: tos_fingerprint)
      verified_seller = create(:user, payment_address: nil, verified: true, user_risk_state: "compliant")
      create(:ach_account, user: verified_seller, stripe_fingerprint: tos_fingerprint)

      described_class.new.perform(@suspended_user.id)

      expect(compliant_seller.reload.on_probation?).to be(true)
      expect(not_reviewed_seller.reload.on_probation?).to be(true)
      expect(verified_seller.reload.on_probation?).to be(true)

      comment = compliant_seller.comments.last
      expect(comment.author_name).to eq(User::Risk::PROBATE_SELLERS_OTHER_ACCOUNTS_AUTHOR_NAME)
      expect(comment.content).to eq("Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{tos_fingerprint} (from suspended for TOS violation User##{@suspended_user.id})")
    end

    it "does not probate users in on_probation, flagged_for_fraud, flagged_for_tos_violation, suspended_for_fraud, or suspended_for_tos_violation states" do
      on_probation_seller = create(:user, payment_address: nil, user_risk_state: "on_probation")
      create(:ach_account, user: on_probation_seller, stripe_fingerprint: tos_fingerprint)
      flagged_fraud_seller = create(:user, payment_address: nil, user_risk_state: "flagged_for_fraud")
      create(:ach_account, user: flagged_fraud_seller, stripe_fingerprint: tos_fingerprint)
      flagged_tos_seller = create(:user, payment_address: nil, user_risk_state: "flagged_for_tos_violation")
      create(:ach_account, user: flagged_tos_seller, stripe_fingerprint: tos_fingerprint)
      suspended_fraud_seller = create(:user, payment_address: nil, user_risk_state: "suspended_for_fraud")
      create(:ach_account, user: suspended_fraud_seller, stripe_fingerprint: tos_fingerprint)
      suspended_tos_seller = create(:user, payment_address: nil, user_risk_state: "suspended_for_tos_violation")
      create(:ach_account, user: suspended_tos_seller, stripe_fingerprint: tos_fingerprint)

      described_class.new.perform(@suspended_user.id)

      expect(on_probation_seller.comments.count).to eq(0)
      expect(on_probation_seller.reload.on_probation?).to be(true)
      expect(flagged_fraud_seller.reload.on_probation?).to be(false)
      expect(flagged_tos_seller.reload.on_probation?).to be(false)
      expect(suspended_fraud_seller.reload.on_probation?).to be(false)
      expect(suspended_tos_seller.reload.on_probation?).to be(false)
    end

    it "does nothing if suspended user has no Stripe fingerprints" do
      suspended_user_no_fingerprints = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: nil)
      other_user = create(:user, payment_address: nil, user_risk_state: "compliant")
      create(:ach_account, user: other_user, stripe_fingerprint: SecureRandom.hex(16))

      described_class.new.perform(suspended_user_no_fingerprints.id)

      expect(other_user.reload.on_probation?).to be(false)
    end
  end
end
