# frozen_string_literal: true

describe CheckPaymentAddressWorker do
  before do
    @previously_banned_user = create(:user, user_risk_state: "suspended_for_fraud", payment_address: "tuhins@gmail.com", updated_at: 1.day.ago)
    @blocked_email_object = BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], "fraudulent_email@zombo.com", nil)
  end

  describe "fraud flagging" do
    it "does not flag the user for fraud if there are no other banned users with the same payment address" do
      @user = create(:user, payment_address: "cleanuser@gmail.com")

      described_class.new.perform(@user.id)

      expect(@user.reload.flagged?).to be(false)
    end

    it "flags the user for fraud if there are other banned users with the same payment address" do
      suspended_user_2 = create(:user, user_risk_state: "suspended_for_fraud", payment_address: "tuhins@gmail.com")
      user = create(:user, payment_address: "tuhins@gmail.com")

      described_class.new.perform(user.id)

      expect(user.reload.flagged?).to be(true)
      comment = user.comments.last
      suspended_for_fraud_uids = [suspended_user_2.external_id, @previously_banned_user.external_id]
      expect(comment.author_name).to eq(described_class::CHECK_PAYMENT_ADDRESS_AUTHOR_NAME)
      expect(comment.content).to eq("Flagged for fraud automatically on #{described_class.formatted_date} because of usage of payment address tuhins@gmail.com (from suspended for fraud Users #{described_class.format_uids(suspended_for_fraud_uids)})")
    end

    it "flags the user for fraud if a blocked email object exists for their payment address" do
      @user = create(:user, payment_address: "fraudulent_email@zombo.com")

      described_class.new.perform(@user.id)

      expect(@user.reload.flagged?).to be(true)
      comment = @user.comments.last
      expect(comment.author_name).to eq(described_class::CHECK_PAYMENT_ADDRESS_AUTHOR_NAME)
      expect(comment.content).to eq("Flagged for fraud automatically on #{described_class.formatted_date} because of usage of payment address fraudulent_email@zombo.com (from a fraudulent purchase)")
    end

    it "flags the user for fraud when both fraud and TOS violations exist" do
      _suspended_tos_user = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: "tuhins@gmail.com")
      user = create(:user, payment_address: "tuhins@gmail.com", verified: false)

      described_class.new.perform(user.id)

      expect(user.reload.flagged?).to be(true)
      expect(user.on_probation?).to be(false)
      comment = user.comments.last
      expect(comment.author_name).to eq(described_class::CHECK_PAYMENT_ADDRESS_AUTHOR_NAME)
      expect(comment.content).to eq("Flagged for fraud automatically on #{described_class.formatted_date} because of usage of payment address tuhins@gmail.com (from suspended for fraud User #{described_class.format_uids([@previously_banned_user.external_id])})")
    end

    it "raises error when attempting to flag verified user for fraud" do
      @user = create(:user, payment_address: "tuhins@gmail.com", verified: true)

      expect { described_class.new.perform(@user.id) }
        .to raise_error(StateMachines::InvalidTransition)
    end
  end

  describe "probation" do
    it "puts user on probation for TOS violations when no fraud violations exist" do
      suspended_tos_user = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: "tos@example.com")
      user = create(:user, payment_address: "tos@example.com", user_risk_state: "not_reviewed")

      described_class.new.perform(user.id)

      expect(user.reload.on_probation?).to be(true)
      comment = user.comments.last
      expect(comment.author_name).to eq(described_class::CHECK_PAYMENT_ADDRESS_AUTHOR_NAME)
      expect(comment.content).to eq("Probated (payouts suspended) automatically on #{described_class.formatted_date} because of usage of payment address tos@example.com (from suspended for TOS violation User #{described_class.format_uids([suspended_tos_user.external_id])})")
    end

    it "puts verified user on probation for TOS violations when no fraud violations exist" do
      suspended_tos_user_1 = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: "tos@example.com", updated_at: 1.day.ago)
      suspended_tos_user_2 = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: "tos@example.com")
      user = create(:user, payment_address: "tos@example.com", verified: true, user_risk_state: "compliant")

      described_class.new.perform(user.id)

      expect(user.reload.on_probation?).to be(true)
      comment = user.comments.last
      expect(comment.author_name).to eq(described_class::CHECK_PAYMENT_ADDRESS_AUTHOR_NAME)
      suspended_for_tos_violation_uids = [suspended_tos_user_2.external_id, suspended_tos_user_1.external_id]
      expect(comment.content).to eq("Probated (payouts suspended) automatically on #{described_class.formatted_date} because of usage of payment address tos@example.com (from suspended for TOS violation Users #{described_class.format_uids(suspended_for_tos_violation_uids)})")
    end
  end
end
