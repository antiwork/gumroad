# frozen_string_literal: true

require "spec_helper"

describe MerchantRegistrationMailer do
  describe "#account_deauthorized_to_user" do
    let(:user) { create(:user) }
    let(:user_id) { user.id }
    let(:charge_processor_id) { StripeChargeProcessor.charge_processor_id }

    let(:mail) do
      described_class.account_deauthorized_to_user(
        user_id,
        charge_processor_id
      )
    end

    it do
      expect(mail.subject).to(include("Payments account disconnected - #{user.external_id}"))
      expect(mail.body.encoded).to(include(charge_processor_id.capitalize))
      expect(mail.body.encoded).to(include("Stripe account disconnected"))
      expect(mail.body.encoded).to(include(settings_payments_url))
    end

    it "shows message for unavailable products" do
      allow_any_instance_of(User).to receive(:can_publish_products?).and_return(false)
      expect(mail.body.encoded).to include("Because both credit cards and PayPal are now turned off for your account," \
                                           " we've disabled your products for sale. You will have to republish them to" \
                                           " enable sales.")
    end
  end

  describe "#account_needs_registration_to_user" do
    let(:charge_processor_id) { StripeChargeProcessor.charge_processor_id }

    context "for an affiliate" do
      let(:affiliate) { create(:direct_affiliate) }
      let(:mail) do
        described_class.account_needs_registration_to_user(
          affiliate.id,
          charge_processor_id
        )
      end

      it "advises the affiliate to connect their account" do
        expect(mail.body.encoded).to(include("You are an affiliate for a creator that has made recent sales"))
        expect(mail.body.encoded).to(include("connected a #{charge_processor_id.capitalize} account"))
      end
    end

    context "for a collaborator" do
      let(:collaborator) { create(:collaborator) }
      let(:mail) do
        described_class.account_needs_registration_to_user(
          collaborator.id,
          charge_processor_id
        )
      end

      it "advises the collaborator to connect their account" do
        expect(mail.body.encoded).to(include("You are a collaborator for a creator that has made recent sales"))
        expect(mail.body.encoded).to(include("connected a #{charge_processor_id.capitalize} account"))
      end
    end
  end

  describe "stripe_charges_disabled" do
    it "alerts the user that payments have been disabled" do
      user = create(:user)
      mail = described_class.stripe_charges_disabled(user.id)

      expect(mail.subject).to eq("Action required: Your sales have stopped")
      expect(mail.to).to include(user.email)
      expect(mail.from).to eq([ApplicationMailer::NOREPLY_EMAIL])
      expect(mail.body.encoded).to include("We have temporarily disabled payments on your account because our payments processor requires more information about you. Since we're subject to their policies, we need to ask you to submit additional documentation.")
      expect(mail.body.encoded).to include("To resume sales:")
      expect(mail.body.encoded).to include("Submit the required documentation")
      expect(mail.body.encoded).to include("We'll review your information")
      expect(mail.body.encoded).to include("Once the verification is successful, which takes around one week, we'll immediately start processing your payments again.")
      expect(mail.body.encoded).to include("Thank you for your patience and understanding.")
    end
  end

  describe "stripe_payouts_disabled" do
    it "notifies the user that their payouts have been paused" do
      user = create(:user)
      mail = described_class.stripe_payouts_disabled(user.id)

      expect(mail.subject).to eq("Action required: Your payouts are paused")
      expect(mail.to).to include(user.email)
      expect(mail.from).to eq([ApplicationMailer::NOREPLY_EMAIL])
      expect(mail.body.encoded).to include("We have temporarily paused payouts on your account because our payments processor requires more information about you.")
      expect(mail.body.encoded).to include("To resume payouts:")
      expect(mail.body.encoded).to include("Submit the required documentation")
      expect(mail.body.encoded).to include("We'll review your information")
      expect(mail.body.encoded).to include("Once the verification is successful, we'll immediately start processing your payouts again.")
      expect(mail.body.encoded).to include("Thank you for your patience and understanding.")
    end
  end

  describe "stripe_payouts_under_review" do
    it "notifies the user that their payouts are paused while under review, with no action needed" do
      user = create(:user)
      mail = described_class.stripe_payouts_under_review(user.id)

      expect(mail.subject).to eq("Your payouts are temporarily paused")
      expect(mail.to).to include(user.email)
      expect(mail.from).to eq([ApplicationMailer::NOREPLY_EMAIL])
      expect(mail.body.encoded).to include("temporarily paused payouts on your account while it completes a review")
      expect(mail.body.encoded).to include("There's nothing you need to do right now.")
      expect(mail.body.encoded).to include("Thank you for your patience and understanding.")
    end
  end

  describe "stripe_account_rejected" do
    let(:user) { create(:user) }
    # The rejected merchant account makes the $1 payout floor apply, which is
    # what lets next_payout_date return a real date for a sub-$100 balance —
    # the same state the email is sent in.
    let!(:merchant_account) { create(:merchant_account, user:, stripe_disabled_reason: "rejected.listed") }

    it "tells the seller the rejection is final and sales have stopped" do
      mail = described_class.stripe_account_rejected(user.id)

      expect(mail.subject).to eq("You can no longer accept payments on Gumroad")
      expect(mail.to).to include(user.email)
      expect(mail.from).to eq([ApplicationMailer::NOREPLY_EMAIL])
      expect(mail.body.encoded).to include("made a final decision to reject it")
      expect(mail.body.encoded).to include("cannot be appealed or reversed")
      expect(mail.body.encoded).to include("Buyers can no longer purchase your products")
      expect(mail.body.encoded).to include("you won't receive any further verification requests")
    end

    it "promises an automatic payout with the date when the balance is payable and Stripe hasn't blocked payouts" do
      create(:balance, user:, amount_cents: 68_17)

      mail = described_class.stripe_account_rejected(user.id)

      expect(mail.body.encoded).to include("$68.17")
      expect(mail.body.encoded).to include("will be paid out to your bank account automatically on #{user.next_payout_date.strftime("%B %-d, %Y")}")
      expect(mail.body.encoded).to include("even though it's below the usual $100 minimum")
      expect(mail.body.encoded).to include("You don't need to do anything")
    end

    it "doesn't claim the balance is below the minimum when it isn't" do
      create(:balance, user:, amount_cents: 250_00)

      mail = described_class.stripe_account_rejected(user.id)

      expect(mail.body.encoded).to include("$250")
      expect(mail.body.encoded).to include("will be paid out to your bank account automatically")
      expect(mail.body.encoded).not_to include("below the usual $100 minimum")
    end

    it "explains the Stripe hold when Stripe disabled payouts on the rejected account" do
      create(:balance, user:, amount_cents: 68_17)
      user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)

      mail = described_class.stripe_account_rejected(user.id)

      expect(mail.body.encoded).to include("is held by Stripe")
      expect(mail.body.encoded).to include("you don't need to do anything")
      expect(mail.body.encoded).not_to include("next scheduled payout")
    end

    it "links support when payouts are paused by something other than Stripe" do
      create(:balance, user:, amount_cents: 68_17)
      user.update!(payouts_paused_by_user: true)

      mail = described_class.stripe_account_rejected(user.id)

      expect(mail.body.encoded).to include("is on hold")
      expect(mail.body.encoded).to include("Contact support")
      expect(mail.body.encoded).to include("we'll help you get it paid out")
    end

    it "explains that a balance under the transfer floor cannot be sent" do
      create(:balance, user:, amount_cents: 50)

      mail = described_class.stripe_account_rejected(user.id)

      expect(mail.body.encoded).to include("below the $1 minimum")
    end
  end
end
