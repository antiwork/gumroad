# frozen_string_literal: true

require "spec_helper"

describe User::Risk do
  describe "#disable_refunds!" do
    before do
      @creator = create(:user)
    end

    it "disables refunds for the creator" do
      @creator.disable_refunds!
      expect(@creator.reload.refunds_disabled?).to eq(true)
    end
  end

  describe "suspension state machine callback" do
    before { Feature.activate(:account_suspended_email) }

    it "sends suspension email when suspended for TOS violation" do
      user = create(:user)
      user.flag_for_tos_violation!(author_name: "admin", bulk: true)

      expect do
        user.suspend_for_tos_violation!(author_name: "admin")
      end.to have_enqueued_mail(ContactingCreatorMailer, :account_suspended).with(user.id)
    end

    it "sends suspension email when suspended for fraud" do
      user = create(:user)
      user.flag_for_fraud!(author_name: "admin")

      expect do
        user.suspend_for_fraud!(author_name: "admin")
      end.to have_enqueued_mail(ContactingCreatorMailer, :account_suspended).with(user.id)
    end

    it "skips the generic suspension email when called with skip_generic_suspension_email" do
      user = create(:user)
      user.flag_for_tos_violation!(author_name: "admin", bulk: true)

      expect do
        user.suspend_for_tos_violation!(author_name: "admin", skip_generic_suspension_email: true)
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :account_suspended)
    end

    it "does not send the generic suspension email when the feature flag is inactive" do
      Feature.deactivate(:account_suspended_email)
      user = create(:user)
      user.flag_for_tos_violation!(author_name: "admin", bulk: true)

      expect do
        user.suspend_for_tos_violation!(author_name: "admin")
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :account_suspended)
    end
  end

  describe "#suspend_due_to_stripe_risk" do
    let(:user) { create(:user) }

    before { Feature.activate(:account_suspended_email) }

    it "sends the Stripe-risk-specific email and not the generic suspension email" do
      expect do
        user.suspend_due_to_stripe_risk
      end.to have_enqueued_mail(ContactingCreatorMailer, :suspended_due_to_stripe_risk).with(user.id).once

      expect do
        create(:user).suspend_due_to_stripe_risk
      end.not_to have_enqueued_mail(ContactingCreatorMailer, :account_suspended)
    end
  end


  describe "#suspend_sellers_other_accounts" do
    let(:transition) { double("transition", args: []) }

    context "when user has PayPal as payout processor" do
      it "calls SuspendAccountsWithPaymentAddressWorker only once for all related accounts" do
        user = create(:user, payment_address: "test@example.com")
        create(:user, payment_address: "test@example.com")

        expect do
          user.suspend_sellers_other_accounts(transition)
        end.to change(SuspendAccountsWithPaymentAddressWorker.jobs, :size).from(0).to(1)
        .and change { SuspendAccountsWithPaymentAddressWorker.jobs.last&.dig("args") }.to([user.id])

        expect do
          SuspendAccountsWithPaymentAddressWorker.perform_one
        end.to change(SuspendAccountsWithPaymentAddressWorker.jobs, :size).from(1).to(0)
      end
    end
  end
end
