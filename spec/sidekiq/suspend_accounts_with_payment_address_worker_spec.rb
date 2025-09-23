# frozen_string_literal: true

describe SuspendAccountsWithPaymentAddressWorker do
  describe "#perform" do
    before do
      @user = create(:user, payment_address: "sameuser@paypal.com")
      @user_2 = create(:user, payment_address: "sameuser@paypal.com")
      create(:user) # admin user
    end

    it "suspends other accounts with the same payment address" do
      described_class.new.perform(@user.id)

      expect(@user_2.reload.suspended?).to be(true)
      expect(@user_2.comments.first.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of payment address #{@user.payment_address} (from User##{@user.id})")
      expect(@user_2.comments.last.content).to eq("Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of payment address #{@user.payment_address} (from User##{@user.id})")
    end
  end
end
