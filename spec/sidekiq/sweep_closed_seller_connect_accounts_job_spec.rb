# frozen_string_literal: true

require "spec_helper"

describe SweepClosedSellerConnectAccountsJob do
  let(:seller) { create(:user, deleted_at: Time.current) }
  let!(:merchant_account) do
    create(:merchant_account, user: seller,
                              charge_processor_id: StripeChargeProcessor.charge_processor_id,
                              charge_processor_merchant_id: "acct_sweep_#{SecureRandom.hex(6)}")
  end
  let(:stripe_account) { Stripe::StripeObject.construct_from(type: "custom") }
  let(:zero_balance) { Stripe::StripeObject.construct_from(available: [{ amount: 0, currency: "usd" }], pending: [{ amount: 0, currency: "usd" }]) }
  let(:balance) { zero_balance }
  let(:message) { @message }

  before do
    allow(Stripe::Account).to receive(:retrieve).and_return(stripe_account)
    allow(Stripe::Balance).to receive(:retrieve).and_return(balance)
    allow(StripeMerchantAccountManager).to receive(:delete_account).and_return(true)
    allow(InternalNotificationWorker).to receive(:perform_async) { |_room, _subject, body| @message = body }
  end

  def run = described_class.new.perform

  context "with the flag off" do
    it "reports an eligible account and deletes nothing" do
      run

      expect(StripeMerchantAccountManager).not_to have_received(:delete_account)
      expect(message).to include("Eligible for deletion (flag off, nothing deleted): 1", merchant_account.charge_processor_merchant_id)
    end
  end

  context "with the flag on" do
    before { Feature.activate(:delete_closed_seller_connect_accounts) }
    after { Feature.deactivate(:delete_closed_seller_connect_accounts) }

    it "deletes at Stripe and marks the record deleted" do
      run

      expect(StripeMerchantAccountManager).to have_received(:delete_account).with(merchant_account)
      expect(merchant_account.reload).to be_deleted
      expect(message).to include("Deleted: 1")
    end

    it "does not select an already-deleted account on a re-run" do
      run
      described_class.new.perform

      expect(StripeMerchantAccountManager).to have_received(:delete_account).once
    end

    it "finishes the local record when Stripe no longer has the account" do
      allow(Stripe::Account).to receive(:retrieve).and_raise(Stripe::InvalidRequestError.new("No such account", nil, code: "resource_missing"))

      run

      expect(StripeMerchantAccountManager).not_to have_received(:delete_account)
      expect(merchant_account.reload.charge_processor_deleted_at).to be_present
    end

    {
      "a non-zero available balance" => { available: [{ amount: 5, currency: "usd" }], pending: [] },
      "a non-zero pending balance" => { available: [], pending: [{ amount: 5, currency: "eur" }] },
      "a negative balance" => { available: [{ amount: -5, currency: "usd" }], pending: [] },
    }.each do |name, attrs|
      it "skips and reports #{name}" do
        allow(Stripe::Balance).to receive(:retrieve).and_return(Stripe::StripeObject.construct_from(attrs))

        run

        expect(StripeMerchantAccountManager).not_to have_received(:delete_account)
        expect(message).to include("Skipped: 1", "non-zero Stripe balance")
      end
    end

    it "skips a standard account" do
      allow(Stripe::Account).to receive(:retrieve).and_return(Stripe::StripeObject.construct_from(type: "standard"))

      run

      expect(StripeMerchantAccountManager).not_to have_received(:delete_account)
      expect(message).to include("not custom")
    end

    it "skips a seller with a successful purchase" do
      create(:free_purchase, link: create(:product, user: seller), seller:)

      run

      expect(StripeMerchantAccountManager).not_to have_received(:delete_account)
      expect(message).to include("successful or in-progress purchase")
    end

    it "skips a seller with a payment being processed" do
      create(:payment, user: seller, state: Payment::PROCESSING)

      run

      expect(StripeMerchantAccountManager).not_to have_received(:delete_account)
      expect(message).to include("payment being created or processed")
    end

    it "skips and reports an uncertain Stripe read" do
      allow(Stripe::Balance).to receive(:retrieve).and_raise(Stripe::APIConnectionError.new("timeout"))

      run

      expect(StripeMerchantAccountManager).not_to have_received(:delete_account)
      expect(message).to include("Skipped: 1", "APIConnectionError")
    end

    it "skips and reports when Stripe does not confirm deletion" do
      allow(StripeMerchantAccountManager).to receive(:delete_account).and_return(false)

      run

      expect(merchant_account.reload).not_to be_deleted
      expect(message).to include("did not confirm deletion")
    end
  end

  it "ignores open sellers, Connect (standard) accounts and PayPal accounts" do
    open_seller = create(:user)
    create(:merchant_account, user: open_seller, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: "acct_open_#{SecureRandom.hex(4)}")
    create(:merchant_account_stripe_connect, user: seller)
    create(:merchant_account_paypal, user: seller)
    merchant_account.update!(charge_processor_deleted_at: Time.current)

    run

    expect(Stripe::Account).not_to have_received(:retrieve)
    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end
end
