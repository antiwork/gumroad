# frozen_string_literal: true

describe CheckPaymentAddressWorker do
  before do
    @previously_banned_user = create(:user, user_risk_state: "suspended_for_fraud", payment_address: "tuhins@gmail.com")
    @blocked_email_object = BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], "fraudulent_email@zombo.com", nil)
  end

  it "does not flag the user for fraud if there are no other banned users with the same payment address" do
    @user = create(:user, payment_address: "cleanuser@gmail.com")

    CheckPaymentAddressWorker.new.perform(@user.id)

    expect(@user.reload.flagged?).to be(false)
  end

  context "when there is a fraud-suspended account with the same payment address" do
    it "flags the user for fraud" do
      @user = create(:user, payment_address: "tuhins@gmail.com")

      CheckPaymentAddressWorker.new.perform(@user.id)

      expect(@user.reload.flagged_for_fraud?).to be(true)
    end
  end

  it "flags the user for fraud if a blocked email object exists for their payment address" do
    @user = create(:user, payment_address: "fraudulent_email@zombo.com")

    CheckPaymentAddressWorker.new.perform(@user.id)

    expect(@user.reload.flagged?).to be(true)
  end

  context "when there is only a TOS-suspended account with the same payment address" do
    before do
      @tos_suspended_user = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: "tosviolator@gmail.com")
    end

    it "puts the user on probation instead of flagging for fraud" do
      @user = create(:user, payment_address: "tosviolator@gmail.com")

      CheckPaymentAddressWorker.new.perform(@user.id)

      expect(@user.reload.on_probation?).to be(true)
      expect(@user.flagged?).to be(false)
      expect(@user.comments.last.content).to eq("Probated for having the same payout address as a previously suspended account (User##{@tos_suspended_user.id})")
    end

    it "does not put the user on probation if already on probation" do
      @user = create(:user, payment_address: "tosviolator@gmail.com", user_risk_state: "on_probation")

      expect { CheckPaymentAddressWorker.new.perform(@user.id) }.not_to change { @user.comments.count }
    end

    it "does not put the user on probation if already flagged" do
      @user = create(:user, payment_address: "tosviolator@gmail.com", user_risk_state: "flagged_for_fraud")

      CheckPaymentAddressWorker.new.perform(@user.id)

      expect(@user.reload.flagged_for_fraud?).to be(true)
      expect(@user.on_probation?).to be(false)
    end
  end

  context "when there are both fraud-suspended and TOS-suspended accounts with the same payment address" do
    before do
      @tos_suspended_user = create(:user, user_risk_state: "suspended_for_tos_violation", payment_address: "tuhins@gmail.com")
    end

    it "flags the user for fraud (fraud takes precedence)" do
      @user = create(:user, payment_address: "tuhins@gmail.com")

      CheckPaymentAddressWorker.new.perform(@user.id)

      expect(@user.reload.flagged_for_fraud?).to be(true)
      expect(@user.on_probation?).to be(false)
    end
  end

  it "does nothing if the user has no payment address" do
    @user = create(:user, payment_address: nil)

    expect { CheckPaymentAddressWorker.new.perform(@user.id) }.not_to change { @user.reload.user_risk_state }
  end

  it "does nothing if the user is not found" do
    expect { CheckPaymentAddressWorker.new.perform(0) }.not_to raise_error
  end
end
