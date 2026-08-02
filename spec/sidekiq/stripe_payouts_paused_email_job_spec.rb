# frozen_string_literal: true

require "spec_helper"

describe StripePayoutsPausedEmailJob do
  let(:user) { create(:user) }
  let(:merchant_account) { create(:merchant_account, user:) }
  let(:claim_token) { SecureRandom.hex(8) }

  before do
    user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
    merchant_account.update!(stripe_payouts_pause_email_sent: "under_review", stripe_payouts_pause_email_claim_token: claim_token)
  end

  def run(email_type: "under_review")
    described_class.new.perform(user.id, merchant_account.id, email_type, claim_token)
  end

  context "when the seller has nothing at stake" do
    it "does not send the under-review email" do
      expect do
        run
      end.to_not have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review)
    end

    it "releases the claim so a later webhook can re-schedule once the seller has stakes" do
      run

      expect(merchant_account.reload.stripe_payouts_pause_email_sent).to be_nil
      expect(merchant_account.stripe_payouts_pause_email_claim_token).to be_nil
    end

    it "still sends the action-required email, which the seller can act on" do
      merchant_account.update!(stripe_payouts_pause_email_sent: "action_required")

      expect do
        run(email_type: "action_required")
      end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_disabled).with(user.id)
    end
  end

  context "when the seller has an unpaid balance" do
    before { create(:balance, user:, amount_cents: 5_00, state: "unpaid") }

    it "sends the under-review email" do
      expect do
        run
      end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review).with(user.id)
    end
  end

  context "when the seller has a successful sale but no balance" do
    before do
      product = create(:product, user:)
      create(:purchase, link: product, seller: user, purchase_state: "successful")
      user.balances.destroy_all
    end

    it "sends the under-review email" do
      expect(user.reload.unpaid_balance_cents).to eq(0)

      expect do
        run
      end.to have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review).with(user.id)
    end
  end

  context "when the seller deactivated their account during the debounce window" do
    before do
      create(:balance, user:, amount_cents: 5_00, state: "unpaid")
      user.update!(deleted_at: Time.current)
    end

    it "does not email a departed seller about a pause they can no longer act on" do
      expect do
        run
      end.to_not have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review)
    end
  end

  context "when the pause resolved before the debounce window elapsed" do
    before { user.update!(payouts_paused_internally: false) }

    it "does not email and releases the claim" do
      expect do
        run
      end.to_not have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review)

      expect(merchant_account.reload.stripe_payouts_pause_email_claim_token).to be_nil
    end
  end

  context "when a newer pause episode has claimed the email" do
    before { merchant_account.update!(stripe_payouts_pause_email_claim_token: "newer-token") }

    it "does not email and leaves the newer claim intact" do
      expect do
        run
      end.to_not have_enqueued_mail(MerchantRegistrationMailer, :stripe_payouts_under_review)

      expect(merchant_account.reload.stripe_payouts_pause_email_claim_token).to eq("newer-token")
    end
  end
end
