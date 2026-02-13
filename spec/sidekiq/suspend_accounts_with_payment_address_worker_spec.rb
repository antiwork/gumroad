# frozen_string_literal: true

describe SuspendAccountsWithPaymentAddressWorker do
  describe "#perform" do
    context "when suspended for fraud" do
      context "with payment address" do
        before do
          @user = create(:user, payment_address: "sameuser@paypal.com")
          @user_2 = create(:user, payment_address: "sameuser@paypal.com")
          create(:user) # admin user
          @user.flag_for_fraud!(author_name: "test")
          @user.suspend_for_fraud!(author_name: "test")
        end

        it "suspends other accounts with the same payment address for fraud" do
          described_class.new.perform(@user.id)

          expect(@user_2.reload.suspended_for_fraud?).to be(true)
          expect(@user_2.comments.where(comment_type: "flagged").last.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of payment address #{@user.payment_address} (from User##{@user.id})")
          expect(@user_2.comments.where(comment_type: "suspended").last.content).to eq("Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of payment address #{@user.payment_address} (from User##{@user.id})")
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

          @user.flag_for_fraud!(author_name: "test")
          @user.suspend_for_fraud!(author_name: "test")
        end

        it "suspends other accounts with the same stripe fingerprint for fraud" do
          described_class.new.perform(@user.id)

          expect(@user_2.reload.suspended_for_fraud?).to be(true)
          expect(@user_3.reload.suspended?).to be(false)
        end

        it "creates both flagged and suspended comments with fingerprint details" do
          described_class.new.perform(@user.id)

          expect(@user_2.reload.comments.where(comment_type: "flagged").last.content).to eq("Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of bank account fingerprint same_fingerprint_123 (from User##{@user.id})")
          expect(@user_2.comments.where(comment_type: "suspended").last.content).to eq("Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of bank account fingerprint same_fingerprint_123 (from User##{@user.id})")
        end
      end
    end

    context "when suspended for TOS violation" do
      context "with payment address" do
        before do
          @user = create(:user, payment_address: "sameuser@paypal.com")
          @user_2 = create(:user, payment_address: "sameuser@paypal.com")
          create(:user) # admin user
          @user.flag_for_tos_violation!(author_name: "test")
          @user.suspend_for_tos_violation!(author_name: "test", skip_transition_callback: :suspend_sellers_other_accounts)
        end

        it "probates other accounts instead of suspending for fraud" do
          described_class.new.perform(@user.id)

          expect(@user_2.reload.on_probation?).to be(true)
          expect(@user_2.suspended?).to be(false)
          expect(@user_2.comments.where(comment_type: "on").last.content).to eq("Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of payment address #{@user.payment_address} (from suspended for TOS violation User##{@user.id})")
        end

        it "does not probate already suspended users" do
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

          @user.flag_for_tos_violation!(author_name: "test")
          @user.suspend_for_tos_violation!(author_name: "test", skip_transition_callback: :suspend_sellers_other_accounts)
        end

        it "probates other accounts with the same stripe fingerprint" do
          described_class.new.perform(@user.id)

          expect(@user_2.reload.on_probation?).to be(true)
          expect(@user_2.suspended?).to be(false)
          expect(@user_3.reload.on_probation?).to be(false)
        end

        it "creates probation comment with fingerprint details" do
          described_class.new.perform(@user.id)

          expect(@user_2.reload.comments.where(comment_type: "on").last.content).to eq("Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of bank account fingerprint same_fingerprint_123 (from suspended for TOS violation User##{@user.id})")
        end
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

      it "suspends accounts matching either payment address or stripe fingerprint when suspended for fraud" do
        @user.flag_for_fraud!(author_name: "test")
        @user.suspend_for_fraud!(author_name: "test")

        described_class.new.perform(@user.id)

        expect(@user_paypal_match.reload.suspended_for_fraud?).to be(true)
        expect(@user_fingerprint_match.reload.suspended_for_fraud?).to be(true)
      end

      it "probates accounts matching either payment address or stripe fingerprint when suspended for TOS violation" do
        @user.flag_for_tos_violation!(author_name: "test")
        @user.suspend_for_tos_violation!(author_name: "test", skip_transition_callback: :suspend_sellers_other_accounts)

        described_class.new.perform(@user.id)

        expect(@user_paypal_match.reload.on_probation?).to be(true)
        expect(@user_fingerprint_match.reload.on_probation?).to be(true)
      end
    end

    context "edge cases" do
      it "does not suspend if fingerprint is blank" do
        user = create(:user)
        user_2 = create(:user)
        bank_account_1 = create(:ach_account, user: user, stripe_fingerprint: nil)
        create(:ach_account, user: user_2, stripe_fingerprint: nil)

        user.flag_for_fraud!(author_name: "test")
        user.suspend_for_fraud!(author_name: "test")

        described_class.new.perform(user.id)

        expect(user_2.reload.suspended?).to be(false)
      end

      it "does not suspend users whose bank accounts are deleted" do
        user = create(:user)
        user_2 = create(:user)
        create(:ach_account, user: user, stripe_fingerprint: "same_fp")
        bank_account_2 = create(:ach_account, user: user_2, stripe_fingerprint: "same_fp")
        bank_account_2.mark_deleted!

        user.flag_for_fraud!(author_name: "test")
        user.suspend_for_fraud!(author_name: "test")

        described_class.new.perform(user.id)

        expect(user_2.reload.suspended?).to be(false)
      end

      it "still suspends related accounts even if suspended user's bank account is deleted" do
        user = create(:user)
        user_2 = create(:user)
        bank_account_1 = create(:ach_account, user: user, stripe_fingerprint: "same_fp")
        create(:ach_account, user: user_2, stripe_fingerprint: "same_fp")
        bank_account_1.mark_deleted!

        user.flag_for_fraud!(author_name: "test")
        user.suspend_for_fraud!(author_name: "test")

        described_class.new.perform(user.id)

        expect(user_2.reload.suspended?).to be(true)
        expect(user_2.comments.where(comment_type: "flagged").last.content).to include("bank account fingerprint same_fp")
      end

      it "checks all fingerprints when suspended user has multiple bank accounts" do
        user = create(:user)
        user_2 = create(:user)
        user_3 = create(:user)
        create(:ach_account, user: user, stripe_fingerprint: "fp_1")
        create(:ach_account, user: user, stripe_fingerprint: "fp_2")
        create(:ach_account, user: user_2, stripe_fingerprint: "fp_1")
        create(:ach_account, user: user_3, stripe_fingerprint: "fp_2")

        user.flag_for_fraud!(author_name: "test")
        user.suspend_for_fraud!(author_name: "test")

        described_class.new.perform(user.id)

        expect(user_2.reload.suspended?).to be(true)
        expect(user_3.reload.suspended?).to be(true)
      end
    end
  end
end
