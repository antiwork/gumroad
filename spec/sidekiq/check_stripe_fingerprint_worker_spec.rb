# frozen_string_literal: true

describe CheckStripeFingerprintWorker do
  let(:stripe_fingerprint) { "acct_fingerprint_123" }

  before do
    @previously_banned_user = create(:user, user_risk_state: "suspended_for_fraud")
    create(:ach_account, user: @previously_banned_user, stripe_fingerprint: stripe_fingerprint)
    @blocked_fingerprint_object = BlockedObject.block!(BLOCKED_OBJECT_TYPES[:stripe_bank_account_fingerprint], "blocked_fingerprint_456", nil)
  end

  it "does not flag the user for fraud if there are no other banned users with the same fingerprint" do
    user = create(:user)
    create(:ach_account, user: user, stripe_fingerprint: "different_fingerprint")

    described_class.new.perform(user.id, "different_fingerprint")

    expect(user.reload.flagged?).to be(false)
  end

  it "flags the user for fraud if there are other banned users with the same fingerprint" do
    user = create(:user)
    create(:ach_account, user: user, stripe_fingerprint: stripe_fingerprint)

    described_class.new.perform(user.id, stripe_fingerprint)

    expect(user.reload.flagged?).to be(true)
  end

  it "flags the user for fraud if a TOS-suspended user has the same fingerprint" do
    tos_suspended_user = create(:user, user_risk_state: "suspended_for_tos_violation")
    create(:ach_account, user: tos_suspended_user, stripe_fingerprint: "tos_fingerprint")

    user = create(:user)
    create(:ach_account, user: user, stripe_fingerprint: "tos_fingerprint")

    described_class.new.perform(user.id, "tos_fingerprint")

    expect(user.reload.flagged?).to be(true)
  end

  it "flags the user for fraud if a blocked fingerprint object exists for their fingerprint" do
    user = create(:user)
    create(:ach_account, user: user, stripe_fingerprint: "blocked_fingerprint_456")

    described_class.new.perform(user.id, "blocked_fingerprint_456")

    expect(user.reload.flagged?).to be(true)
  end

  it "does not flag the user if they are already flagged" do
    user = create(:user, user_risk_state: "flagged_for_fraud")
    create(:ach_account, user: user, stripe_fingerprint: stripe_fingerprint)

    described_class.new.perform(user.id, stripe_fingerprint)

    expect(user.reload.user_risk_state).to eq("flagged_for_fraud")
  end

  it "does not flag the user if the fingerprint is blank" do
    user = create(:user)
    create(:ach_account, user: user, stripe_fingerprint: nil)

    described_class.new.perform(user.id, nil)

    expect(user.reload.flagged?).to be(false)
  end

  it "does not flag the user if they cannot be flagged for fraud" do
    user = create(:user, user_risk_state: "suspended_for_fraud")
    create(:ach_account, user: user, stripe_fingerprint: stripe_fingerprint)

    described_class.new.perform(user.id, stripe_fingerprint)

    expect(user.reload.user_risk_state).to eq("suspended_for_fraud")
  end

  it "ignores deleted bank accounts when checking for suspended users" do
    @previously_banned_user.active_bank_account.mark_deleted!

    user = create(:user)
    create(:ach_account, user: user, stripe_fingerprint: stripe_fingerprint)

    described_class.new.perform(user.id, stripe_fingerprint)

    expect(user.reload.flagged?).to be(false)
  end
end
