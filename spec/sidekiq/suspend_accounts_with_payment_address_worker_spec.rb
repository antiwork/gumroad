# frozen_string_literal: true

describe SuspendAccountsWithPaymentAddressWorker do
  describe "#perform" do
    before do
      @user = create(:user, payment_address: "sameuser@paypal.com")
      @user_2 = create(:user, payment_address: "sameuser@paypal.com")
      create(:user) # admin user
    end

    context "when suspended for fraud" do
      before do
        @user.update!(user_risk_state: "suspended_for_fraud")
      end

      it "suspends other accounts with the same payment address for fraud" do
        described_class.new.perform(@user.id)

        expect(@user_2.reload.suspended_for_fraud?).to be(true)
        expect(@user_2.comments.first.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of payment address #{@user.payment_address} (from User##{@user.id})")
        expect(@user_2.comments.last.content).to eq("Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of payment address #{@user.payment_address} (from User##{@user.id})")
      end
    end

    context "when suspended for TOS violation" do
      before do
        @user.update!(user_risk_state: "suspended_for_tos_violation")
      end

      it "puts other accounts on probation instead of suspending for fraud" do
        described_class.new.perform(@user.id)

        expect(@user_2.reload.on_probation?).to be(true)
        expect(@user_2.suspended?).to be(false)
        expect(@user_2.comments.last.content).to eq("Probated automatically on #{Time.current.to_fs(:formatted_date_full_month)} for having the same payout address as a previously suspended account (User##{@user.id})")
      end

      it "skips users who are already on probation" do
        @user_2.update!(user_risk_state: "on_probation")

        expect { described_class.new.perform(@user.id) }.not_to change { @user_2.comments.count }
        expect(@user_2.reload.on_probation?).to be(true)
      end

      it "skips users who are already flagged" do
        @user_2.update!(user_risk_state: "flagged_for_fraud")

        expect { described_class.new.perform(@user.id) }.not_to change { @user_2.comments.count }
        expect(@user_2.reload.flagged_for_fraud?).to be(true)
      end
    end

    it "does nothing if the suspended user has no payment address" do
      @user.update!(payment_address: nil, user_risk_state: "suspended_for_fraud")

      expect { described_class.new.perform(@user.id) }.not_to change { @user_2.reload.user_risk_state }
    end
  end
end
