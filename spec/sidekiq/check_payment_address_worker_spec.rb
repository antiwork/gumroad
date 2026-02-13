# frozen_string_literal: true

describe CheckPaymentAddressWorker do
  describe "payment address checks" do
    before do
      @previously_banned_user = create(:user, user_risk_state: "suspended_for_fraud", payment_address: "tuhins@gmail.com")
      @blocked_email_object = BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], "fraudulent_email@zombo.com", nil)
    end

    it "does not flag the user for fraud if there are no other banned users with the same payment address" do
      @user = create(:user, payment_address: "cleanuser@gmail.com")

      CheckPaymentAddressWorker.new.perform(@user.id)

      expect(@user.reload.flagged?).to be(false)
    end

    it "flags the user for fraud if there are other fraud-suspended users with the same payment address" do
      @user = create(:user, payment_address: "tuhins@gmail.com")

      CheckPaymentAddressWorker.new.perform(@user.id)

      expect(@user.reload.flagged_for_fraud?).to be(true)
    end

    it "flags the user for fraud if a blocked email object exists for their payment address" do
      @user = create(:user, payment_address: "fraudulent_email@zombo.com")

      CheckPaymentAddressWorker.new.perform(@user.id)

      expect(@user.reload.flagged_for_fraud?).to be(true)
    end

    it "probates the user if matching account is suspended for TOS violation" do
      tos_user = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: "tos_violator@gmail.com")
      user = create(:user, payment_address: "tos_violator@gmail.com")

      CheckPaymentAddressWorker.new.perform(user.id)

      expect(user.reload.on_probation?).to be(true)
      expect(user.comments.where(comment_type: "on").last.content).to include("suspended for TOS violation")
      expect(user.comments.where(comment_type: "on").last.content).to include("User##{tos_user.id}")
    end

    it "flags for fraud instead of probation when both fraud and TOS matches exist" do
      tos_user = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: "shared@gmail.com")
      fraud_user = create(:user, user_risk_state: "suspended_for_fraud", payment_address: "shared@gmail.com")
      user = create(:user, payment_address: "shared@gmail.com")

      CheckPaymentAddressWorker.new.perform(user.id)

      expect(user.reload.flagged_for_fraud?).to be(true)
    end
  end

  describe "stripe fingerprint checks" do
    it "does not flag the user for fraud if there are no suspended users with the same stripe fingerprint" do
      user = create(:user)
      create(:ach_account, user:, stripe_fingerprint: "clean_fingerprint")

      other_user = create(:user)
      create(:ach_account, user: other_user, stripe_fingerprint: "different_fingerprint")

      CheckPaymentAddressWorker.new.perform(user.id)

      expect(user.reload.flagged?).to be(false)
    end

    it "flags the user for fraud if a fraud-suspended user has the same stripe fingerprint" do
      suspended_user = create(:user, user_risk_state: "suspended_for_fraud")
      create(:ach_account, user: suspended_user, stripe_fingerprint: "same_fingerprint_123")

      user = create(:user)
      create(:ach_account, user:, stripe_fingerprint: "same_fingerprint_123")

      CheckPaymentAddressWorker.new.perform(user.id)

      expect(user.reload.flagged_for_fraud?).to be(true)
    end

    it "probates the user if a TOS-suspended user has the same stripe fingerprint" do
      suspended_user = create(:user, user_risk_state: "suspended_for_tos_violation")
      create(:ach_account, user: suspended_user, stripe_fingerprint: "same_fingerprint_456")

      user = create(:user)
      create(:ach_account, user:, stripe_fingerprint: "same_fingerprint_456")

      CheckPaymentAddressWorker.new.perform(user.id)

      expect(user.reload.on_probation?).to be(true)
      expect(user.comments.where(comment_type: "on").last.content).to include("suspended for TOS violation")
    end

    it "flags the user for fraud if a blocked fingerprint object exists" do
      user = create(:user)
      create(:ach_account, user:, stripe_fingerprint: "blocked_fingerprint")
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint], "blocked_fingerprint", nil)

      CheckPaymentAddressWorker.new.perform(user.id)

      expect(user.reload.flagged_for_fraud?).to be(true)
    end

    it "flags the user even if the suspended user's bank account is deleted (fraud history is preserved)" do
      suspended_user = create(:user, user_risk_state: "suspended_for_fraud")
      bank_account = create(:ach_account, user: suspended_user, stripe_fingerprint: "same_fingerprint_789")
      bank_account.mark_deleted!

      user = create(:user)
      create(:ach_account, user:, stripe_fingerprint: "same_fingerprint_789")

      CheckPaymentAddressWorker.new.perform(user.id)

      expect(user.reload.flagged_for_fraud?).to be(true)
    end

    it "does not flag if the new user's bank account is deleted" do
      suspended_user = create(:user, user_risk_state: "suspended_for_fraud")
      create(:ach_account, user: suspended_user, stripe_fingerprint: "same_fingerprint_abc")

      user = create(:user)
      bank_account = create(:ach_account, user:, stripe_fingerprint: "same_fingerprint_abc")
      bank_account.mark_deleted!

      CheckPaymentAddressWorker.new.perform(user.id)

      expect(user.reload.flagged?).to be(false)
    end

    it "does not flag if stripe fingerprint is blank" do
      user = create(:user)
      create(:ach_account, user:, stripe_fingerprint: nil)

      CheckPaymentAddressWorker.new.perform(user.id)

      expect(user.reload.flagged?).to be(false)
    end

    it "checks all fingerprints when new user has multiple bank accounts" do
      suspended_user = create(:user, user_risk_state: "suspended_for_fraud")
      create(:ach_account, user: suspended_user, stripe_fingerprint: "fraud_fingerprint")

      user = create(:user)
      create(:ach_account, user:, stripe_fingerprint: "clean_fingerprint")
      create(:ach_account, user:, stripe_fingerprint: "fraud_fingerprint")

      CheckPaymentAddressWorker.new.perform(user.id)

      expect(user.reload.flagged_for_fraud?).to be(true)
    end

    it "flags if any of the user's fingerprints is blocked" do
      user = create(:user)
      create(:ach_account, user:, stripe_fingerprint: "clean_fingerprint")
      create(:ach_account, user:, stripe_fingerprint: "blocked_fingerprint_xyz")
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint], "blocked_fingerprint_xyz", nil)

      CheckPaymentAddressWorker.new.perform(user.id)

      expect(user.reload.flagged_for_fraud?).to be(true)
    end
  end

  describe "edge cases" do
    it "does not flag the user if they cannot be flagged for fraud" do
      suspended_user = create(:user, user_risk_state: "suspended_for_fraud")
      create(:ach_account, user: suspended_user, stripe_fingerprint: "same_fingerprint")

      already_flagged_user = create(:user, user_risk_state: "flagged_for_fraud")
      create(:ach_account, user: already_flagged_user, stripe_fingerprint: "same_fingerprint")

      CheckPaymentAddressWorker.new.perform(already_flagged_user.id)

      expect(already_flagged_user.reload.user_risk_state).to eq("flagged_for_fraud")
    end

    it "does not probate a user who is already on probation" do
      tos_user = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: "tos@example.com")
      user = create(:user, user_risk_state: "on_probation", payment_address: "tos@example.com")
      initial_comment_count = user.comments.count

      CheckPaymentAddressWorker.new.perform(user.id)

      expect(user.reload.on_probation?).to be(true)
      expect(user.comments.count).to eq(initial_comment_count)
    end

    it "does not probate a suspended user" do
      tos_user = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: "tos@example.com")
      user = create(:user, user_risk_state: "suspended_for_fraud", payment_address: "tos@example.com")
      initial_comment_count = user.comments.count

      CheckPaymentAddressWorker.new.perform(user.id)

      expect(user.reload.suspended_for_fraud?).to be(true)
      expect(user.comments.count).to eq(initial_comment_count)
    end

    it "does not raise error if user is not found" do
      expect { CheckPaymentAddressWorker.new.perform(999999999) }.not_to raise_error
    end
  end
end
