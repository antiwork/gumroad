# frozen_string_literal: true

describe FlagForFraudStripeFingerprintWorker do
  let(:banned_fingerprint) { SecureRandom.hex(16) }
  let(:blocked_fingerprint) { SecureRandom.hex(16) }

  let!(:_previously_banned_user_with_stripe_bank_account) do
    user = create(:user, user_risk_state: "suspended_for_fraud", payment_address: nil)
    create(:ach_account, user: user, stripe_fingerprint: banned_fingerprint)
    user
  end

  let!(:user) { create(:user) }

  describe "fraud flagging" do
    it "does not flag the user for fraud if there are no other banned users with the same Stripe fingerprint" do
      create(:ach_account, user: user, stripe_fingerprint: "clean_fingerprint")
      expect(user.flagged?).to be(false)

      described_class.new.perform(user.id)
      expect(user.reload.flagged?).to be(false)
    end

    it "flags the user for fraud when banned Stripe fingerprint(s) match" do
      create(:ach_account, user:, stripe_fingerprint: banned_fingerprint)

      described_class.new.perform(user.id)

      expect(user.reload.flagged?).to be(true)
      last_comment = user.comments.last
      expect(last_comment.author_name).to eq(described_class::FLAG_FOR_FRAUD_STRIPE_FINGERPRINT_AUTHOR_NAME)
      expect(last_comment.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{banned_fingerprint} (from suspended for fraud User #{described_class.format_uids([_previously_banned_user_with_stripe_bank_account.external_id])})")

      banned_fingerprint = SecureRandom.hex(16)
      banned_fingerprint_2 = SecureRandom.hex(16)
      banned_user_1 = create(:user, user_risk_state: "suspended_for_fraud", payment_address: nil, updated_at: 2.days.ago)
      create(:ach_account, user: banned_user_1, stripe_fingerprint: banned_fingerprint)
      banned_user_2 = create(:user, user_risk_state: "suspended_for_fraud", payment_address: nil, updated_at: 1.day.ago)
      create(:ach_account, user: banned_user_2, stripe_fingerprint: banned_fingerprint_2)
      user_with_both = create(:user)
      create(:ach_account, user: user_with_both, stripe_fingerprint: banned_fingerprint)
      create(:ach_account, user: user_with_both, stripe_fingerprint: banned_fingerprint_2)

      described_class.new.perform(user_with_both.id)

      expect(user_with_both.reload.flagged?).to be(true)
      last_comment = user_with_both.comments.last
      suspended_for_fraud_uids = [banned_user_2.external_id, banned_user_1.external_id]
      expect(last_comment.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprints #{[banned_fingerprint, banned_fingerprint_2].sort.to_sentence} (from suspended for fraud Users #{described_class.format_uids(suspended_for_fraud_uids)})")
    end

    it "flags the user for fraud when blocked Stripe fingerprint(s) match" do
      blocked_purchase_fingerprint = SecureRandom.hex(16)
      user_with_multiple_banned_fingerprints = create(:user)
      create(:ach_account, user:, stripe_fingerprint: blocked_fingerprint)
      create(:ach_account, user: user_with_multiple_banned_fingerprints, stripe_fingerprint: blocked_fingerprint)
      create(:ach_account, user: user_with_multiple_banned_fingerprints, stripe_fingerprint: blocked_purchase_fingerprint)
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint], blocked_fingerprint, nil)
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint], blocked_purchase_fingerprint, nil)

      described_class.new.perform(user.id)

      expect(user.reload.flagged?).to be(true)
      last_comment = user.comments.last
      expect(last_comment.author_name).to eq(described_class::FLAG_FOR_FRAUD_STRIPE_FINGERPRINT_AUTHOR_NAME)
      expect(last_comment.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{blocked_fingerprint} (from a fraudulent purchase)")

      described_class.new.perform(user_with_multiple_banned_fingerprints.id)

      expect(user_with_multiple_banned_fingerprints.reload.flagged?).to be(true)
      last_comment = user_with_multiple_banned_fingerprints.comments.last
      expect(last_comment.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprints #{[blocked_fingerprint, blocked_purchase_fingerprint].sort.to_sentence} (from a fraudulent purchase)")
    end

    it "flags the user for fraud when both fraud and TOS violations exist" do
      tos_fingerprint = banned_fingerprint
      suspended_tos_user = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: nil)
      create(:ach_account, user: suspended_tos_user, stripe_fingerprint: tos_fingerprint)
      create(:ach_account, user:, stripe_fingerprint: tos_fingerprint)

      described_class.new.perform(user.id)

      expect(user.reload.flagged?).to be(true)
      expect(user.on_probation?).to be(false)
      last_comment = user.comments.last
      expect(last_comment.author_name).to eq(described_class::FLAG_FOR_FRAUD_STRIPE_FINGERPRINT_AUTHOR_NAME)
      expect(last_comment.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{tos_fingerprint} (from suspended for fraud User #{described_class.format_uids([_previously_banned_user_with_stripe_bank_account.external_id])})")
    end

    it "does not raise when user_id is missing" do
      expect { described_class.new.perform(User.maximum(:id).to_i + 1) }.not_to raise_error
    end
  end

  describe "probation" do
    it "puts user on probation for TOS violations when no fraud violations exist" do
      tos_fingerprint = SecureRandom.hex(16)
      suspended_tos_user = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: nil)
      create(:ach_account, user: suspended_tos_user, stripe_fingerprint: tos_fingerprint)
      user_on_check = create(:user, user_risk_state: "not_reviewed")
      create(:ach_account, user: user_on_check, stripe_fingerprint: tos_fingerprint)

      described_class.new.perform(user_on_check.id)

      expect(user_on_check.reload.on_probation?).to be(true)
      last_comment = user_on_check.comments.last
      expect(last_comment.author_name).to eq(described_class::FLAG_FOR_FRAUD_STRIPE_FINGERPRINT_AUTHOR_NAME)
      expect(last_comment.content).to eq("Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{tos_fingerprint} (from suspended for TOS violation User #{described_class.format_uids([suspended_tos_user.external_id])})")
    end

    it "puts user on probation with plural fingerprint wording when multiple TOS fingerprints match" do
      tos_fp_1 = SecureRandom.hex(16)
      tos_fp_2 = SecureRandom.hex(16)
      suspended_tos_1 = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: nil)
      create(:ach_account, user: suspended_tos_1, stripe_fingerprint: tos_fp_1)
      suspended_tos_2 = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: nil)
      create(:ach_account, user: suspended_tos_2, stripe_fingerprint: tos_fp_2)
      user_on_check = create(:user, user_risk_state: "not_reviewed")
      create(:ach_account, user: user_on_check, stripe_fingerprint: tos_fp_1)
      create(:ach_account, user: user_on_check, stripe_fingerprint: tos_fp_2)

      described_class.new.perform(user_on_check.id)

      expect(user_on_check.reload.on_probation?).to be(true)
      last_comment = user_on_check.comments.last
      expect(last_comment.content).to include("Stripe fingerprints ")
      expect(last_comment.content).to include(tos_fp_1)
      expect(last_comment.content).to include(tos_fp_2)
      expect(last_comment.content).to include("from suspended for TOS violation Users")
    end

    it "puts compliant user on probation for TOS violations when no fraud violations exist" do
      tos_fingerprint = SecureRandom.hex(16)
      suspended_tos_user_1 = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: nil, updated_at: 1.day.ago)
      create(:ach_account, user: suspended_tos_user_1, stripe_fingerprint: tos_fingerprint)
      suspended_tos_user_2 = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: nil)
      create(:ach_account, user: suspended_tos_user_2, stripe_fingerprint: tos_fingerprint)
      user_on_check = create(:user, user_risk_state: "compliant")
      create(:ach_account, user: user_on_check, stripe_fingerprint: tos_fingerprint)

      described_class.new.perform(user_on_check.id)

      expect(user_on_check.reload.on_probation?).to be(true)
      last_comment = user_on_check.comments.last
      expect(last_comment.author_name).to eq(described_class::FLAG_FOR_FRAUD_STRIPE_FINGERPRINT_AUTHOR_NAME)
      suspended_for_tos_violation_uids = [suspended_tos_user_2.external_id, suspended_tos_user_1.external_id]
      expect(last_comment.content).to eq("Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{tos_fingerprint} (from suspended for TOS violation Users #{described_class.format_uids(suspended_for_tos_violation_uids)})")
    end
  end
end
