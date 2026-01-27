# frozen_string_literal: true

describe MarkAccountsCompliantWithStripeFingerprintWorker do
  describe "#perform" do
    it "marks sellers related accounts with same Stripe fingerprint as compliant" do
      fingerprint = SecureRandom.hex(16)
      user = create(:user, user_risk_state: "compliant", payment_address: nil)
      user_2 = create(:user, user_risk_state: "suspended_for_fraud", payment_address: nil)
      user_3 = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: nil)
      user_4 = create(:user, user_risk_state: "flagged_for_fraud", payment_address: nil)
      user_5 = create(:user, user_risk_state: "flagged_for_tos_violation", payment_address: nil)
      user_6 = create(:user, payment_address: nil)
      [user, user_2, user_3, user_4, user_5, user_6].each do |user|
        create(:user_compliance_info, user:)
        create(:ach_account, user:, stripe_fingerprint: fingerprint)
      end

      described_class.new.perform(user.id)

      compliant_comment_content = "Marked compliant automatically on #{Time.current.to_fs(:formatted_date_full_month)} as Stripe fingerprint #{fingerprint} now unblocked (from User##{user.id})"
      [user_2, user_3, user_4, user_5, user_6].each do |user|
        expect(user.reload.comments.count).to eq(1)
        expect(user.compliant?).to be(true)
        expect(user.comments.last.content).to eq(compliant_comment_content)
        expect(user.comments.last.author_name).to eq(User::Risk::ENABLE_SELLER_ACCOUNTS_AUTHOR_NAME)
      end
    end

    it "marks other seller accounts as compliant when compliant user updated their only matching bank account" do
      fingerprint = SecureRandom.hex(16)
      compliant_user = create(:user, user_risk_state: "compliant", payment_address: nil)
      create(:user_compliance_info, user: compliant_user)
      previous_account = create(:ach_account, user: compliant_user, stripe_fingerprint: fingerprint)
      previous_account.mark_deleted!
      create(:ach_account, user: compliant_user, stripe_fingerprint: SecureRandom.hex(16))
      user_to_unblock = create(:user, user_risk_state: "suspended_for_fraud", payment_address: nil)
      create(:user_compliance_info, user: user_to_unblock)
      create(:ach_account, user: user_to_unblock, stripe_fingerprint: fingerprint)

      described_class.new.perform(compliant_user.id)

      expect(user_to_unblock.reload.compliant?).to be(true)
      expect(user_to_unblock.comments.count).to eq(1)
      expect(user_to_unblock.comments.last.content).to eq("Marked compliant automatically on #{Time.current.to_fs(:formatted_date_full_month)} as Stripe fingerprint #{fingerprint} now unblocked (from User##{compliant_user.id})")
      expect(user_to_unblock.comments.last.author_name).to eq(User::Risk::ENABLE_SELLER_ACCOUNTS_AUTHOR_NAME)
    end
  end
end
