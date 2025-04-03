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

  it "flags the user for fraud if there are other banned users with the same payment address" do
    @user = create(:user, payment_address: "tuhins@gmail.com")

    CheckPaymentAddressWorker.new.perform(@user.id)

    expect(@user.reload.flagged?).to be(true)
  end

  it "flags the user for fraud if a blocked email object exists for their payment address" do
    @user = create(:user, payment_address: "fraudulent_email@zombo.com")

    CheckPaymentAddressWorker.new.perform(@user.id)

    expect(@user.reload.flagged?).to be(true)
  end
end
