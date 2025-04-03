# frozen_string_literal: true

describe SendPaymentReminderWorker do
  describe "perform" do
    before do
      @user = create(:user, payment_address: nil)
      create(:balance, user: @user, amount_cents: 1001)
    end

    it "notifies users to update payment information" do
      expect do
        described_class.new.perform
      end.to have_enqueued_mail(ContactingCreatorMailer, :remind).with(@user.id)
    end

    it "does not notify the user to update payment information if they have an active stripe connect account" do
      create(:merchant_account_stripe_connect, user: @user)
      expect do
        described_class.new.perform
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :remind).with(@user.id)

      @user.stripe_connect_account.mark_deleted!
      expect do
        described_class.new.perform
      end.to have_enqueued_mail(ContactingCreatorMailer, :remind).with(@user.id)
    end

    it "does not notify the user to update payment information if they have an active paypal connect account" do
      create(:merchant_account_paypal, user: @user)
      expect do
        described_class.new.perform
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :remind).with(@user.id)

      @user.paypal_connect_account.mark_deleted!
      expect do
        described_class.new.perform
      end.to have_enqueued_mail(ContactingCreatorMailer, :remind).with(@user.id)
    end

    it "does not notify the user to update payment information if they have an active bank account" do
      create(:ach_account, user: @user)
      expect do
        described_class.new.perform
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :remind).with(@user.id)

      @user.active_bank_account.mark_deleted!
      expect do
        described_class.new.perform
      end.to have_enqueued_mail(ContactingCreatorMailer, :remind).with(@user.id)
    end
  end
end
