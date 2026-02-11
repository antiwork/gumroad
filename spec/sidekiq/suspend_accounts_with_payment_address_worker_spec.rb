# frozen_string_literal: true

describe SuspendAccountsWithPaymentAddressWorker do
  describe "#perform" do
    context "with payment address" do
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

      it "does not suspend already suspended users with same payment address" do
        @user_2.flag_for_fraud!(author_name: "test")
        @user_2.suspend_for_fraud!(author_name: "test")
        initial_comment_count = @user_2.comments.count

        described_class.new.perform(@user.id)

        expect(@user_2.reload.comments.count).to eq(initial_comment_count)
      end
    end

    context "with stripe fingerprint" do
      before do
        @user = create(:user)
        @user_2 = create(:user)
        @user_3 = create(:user)

        @bank_account_1 = create(:ach_account, user: @user, stripe_fingerprint: "same_fingerprint_123")
        @bank_account_2 = create(:ach_account, user: @user_2, stripe_fingerprint: "same_fingerprint_123")
        @bank_account_3 = create(:ach_account, user: @user_3, stripe_fingerprint: "different_fingerprint")
      end

      it "suspends other accounts with the same stripe fingerprint" do
        described_class.new.perform(@user.id)

        expect(@user_2.reload.suspended?).to be(true)
        expect(@user_3.reload.suspended?).to be(false)
      end

      it "creates both flagged and suspended comments with fingerprint details" do
        described_class.new.perform(@user.id)

        expect(@user_2.reload.comments.first.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of bank account fingerprint same_fingerprint_123 (from User##{@user.id})")
        expect(@user_2.comments.last.content).to eq("Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of bank account fingerprint same_fingerprint_123 (from User##{@user.id})")
      end

      it "does not suspend if fingerprint is blank" do
        @bank_account_1.update!(stripe_fingerprint: nil)

        described_class.new.perform(@user.id)

        expect(@user_2.reload.suspended?).to be(false)
      end

      it "does not suspend users whose bank accounts are deleted" do
        @bank_account_2.mark_deleted!

        described_class.new.perform(@user.id)

        expect(@user_2.reload.suspended?).to be(false)
      end

      it "does not suspend already suspended users" do
        @user_2.flag_for_fraud!(author_name: "test")
        @user_2.suspend_for_fraud!(author_name: "test")
        initial_comment_count = @user_2.comments.count

        described_class.new.perform(@user.id)

        expect(@user_2.reload.comments.count).to eq(initial_comment_count)
      end

      it "still suspends related accounts even if suspended user's bank account is deleted" do
        @bank_account_1.mark_deleted!

        described_class.new.perform(@user.id)

        expect(@user_2.reload.suspended?).to be(true)
        expect(@user_2.comments.first.content).to include("bank account fingerprint same_fingerprint_123")
      end

      it "checks all fingerprints when suspended user has multiple bank accounts" do
        create(:ach_account, user: @user, stripe_fingerprint: "another_fingerprint")
        user_with_another_fingerprint = create(:user)
        create(:ach_account, user: user_with_another_fingerprint, stripe_fingerprint: "another_fingerprint")

        described_class.new.perform(@user.id)

        expect(@user_2.reload.suspended?).to be(true)
        expect(user_with_another_fingerprint.reload.suspended?).to be(true)
      end

      it "uses the matching fingerprint in the comment when user has multiple fingerprints" do
        create(:ach_account, user: @user, stripe_fingerprint: "another_fingerprint")
        user_with_another_fingerprint = create(:user)
        create(:ach_account, user: user_with_another_fingerprint, stripe_fingerprint: "another_fingerprint")

        described_class.new.perform(@user.id)

        expect(user_with_another_fingerprint.reload.comments.first.content).to include("another_fingerprint")
      end
    end

    context "with both payment address and stripe fingerprint" do
      before do
        @user = create(:user, payment_address: "sameuser@paypal.com")
        @user_paypal_match = create(:user, payment_address: "sameuser@paypal.com")
        @user_fingerprint_match = create(:user)

        @bank_account_1 = create(:ach_account, user: @user, stripe_fingerprint: "same_fingerprint_123")
        @bank_account_2 = create(:ach_account, user: @user_fingerprint_match, stripe_fingerprint: "same_fingerprint_123")
      end

      it "suspends accounts matching either payment address or stripe fingerprint" do
        described_class.new.perform(@user.id)

        expect(@user_paypal_match.reload.suspended?).to be(true)
        expect(@user_fingerprint_match.reload.suspended?).to be(true)
      end
    end
  end
end
