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

  it "flags the user for fraud if there are other banned users with the same Stripe fingerprint" do
    create(:ach_account, user:, stripe_fingerprint: banned_fingerprint)
    expect(user.flagged?).to be(false)

    FlagForFraudStripeFingerprintWorker.new.perform(user.id)
    expect(user.reload.flagged?).to be(true)
    last_comment = user.comments.last
    expect(last_comment.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{banned_fingerprint}")
    expect(last_comment.author_name).to eq("FlagForFraudStripeFingerprintWorker")
  end

  it "flags the user for fraud if a purchase with blocked Stripe fingerprint exists" do
    stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
    purchase = create(:purchase, purchaser: user, stripe_fingerprint: blocked_fingerprint)
    purchase.block_buyer!
    create(:ach_account, user:, stripe_fingerprint: blocked_fingerprint)
    expect(purchase.blocked_by_charge_processor_fingerprint?).to be(true)
    expect(user.flagged?).to be(false)

    FlagForFraudStripeFingerprintWorker.new.perform(user.id)
    expect(user.reload.flagged?).to be(true)
    last_comment = user.comments.last
    expect(last_comment.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of Stripe fingerprint #{blocked_fingerprint}")
    expect(last_comment.author_name).to eq("FlagForFraudStripeFingerprintWorker")
  end

  it "does not flag the user for fraud if there are no other banned users with the same Stripe fingerprint" do
    create(:ach_account, user: user, stripe_fingerprint: "clean_fingerprint")
    expect(user.flagged?).to be(false)

    FlagForFraudStripeFingerprintWorker.new.perform(user.id)
    expect(user.reload.flagged?).to be(false)
  end
end
