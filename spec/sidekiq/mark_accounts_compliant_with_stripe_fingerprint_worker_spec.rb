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

      compliant_comment_content = "Marked compliant automatically on #{Time.current.to_fs(:formatted_date_full_month)} as Stripe fingerprint #{fingerprint} is now unblocked (from User##{user.id})"
      [user_2, user_3, user_4, user_5, user_6].each do |user|
        expect(user.reload.comments.count).to eq(1)
        expect(user.compliant?).to be(true)
        expect(user.comments.last.content).to eq(compliant_comment_content)
        expect(user.comments.last.author_name).to eq(User::Risk::ENABLE_SELLER_ACCOUNTS_AUTHOR_NAME)
      end
    end
  end
end
