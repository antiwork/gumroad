# frozen_string_literal: true

require "spec_helper"

describe RefreshMerchantAccountPaymentMethodAvailabilityWorker do
  let(:seller) { create(:user, check_merchant_account_is_linked: true) }
  let(:merchant_account) { create(:merchant_account_stripe_connect, user: seller) }

  it "refreshes the availability snapshot for a live connect account" do
    service = instance_double(StripeConnectPaymentMethodAvailabilityService)
    expect(StripeConnectPaymentMethodAvailabilityService).to receive(:new).with(merchant_account).and_return(service)
    expect(service).to receive(:refresh!)

    described_class.new.perform(merchant_account.id)
  end

  it "skips deleted accounts" do
    merchant_account.mark_deleted!

    expect(StripeConnectPaymentMethodAvailabilityService).not_to receive(:new)
    described_class.new.perform(merchant_account.id)
  end

  it "skips accounts whose charge processor connection is dead" do
    merchant_account.update!(charge_processor_alive_at: nil, charge_processor_deleted_at: Time.current)

    expect(StripeConnectPaymentMethodAvailabilityService).not_to receive(:new)
    described_class.new.perform(merchant_account.id)
  end

  it "skips Gumroad-managed accounts — their charges run on the platform account" do
    managed = create(:merchant_account, user: seller)

    expect(StripeConnectPaymentMethodAvailabilityService).not_to receive(:new)
    described_class.new.perform(managed.id)
  end

  it "swallows a permission error — the account was deauthorized between enqueue and execution" do
    allow_any_instance_of(StripeConnectPaymentMethodAvailabilityService).to receive(:refresh!)
      .and_raise(Stripe::PermissionError.new("Application access may have been revoked."))

    expect { described_class.new.perform(merchant_account.id) }.not_to raise_error
  end

  it "swallows an authentication error — some deauthorized accounts return this instead of a permission error" do
    allow_any_instance_of(StripeConnectPaymentMethodAvailabilityService).to receive(:refresh!)
      .and_raise(Stripe::AuthenticationError.new("The provided key does not have access to this account."))

    expect { described_class.new.perform(merchant_account.id) }.not_to raise_error
  end

  it "swallows an invalid-request error for a Stripe-side-deleted account — the race before our deauth webhook is processed" do
    allow_any_instance_of(StripeConnectPaymentMethodAvailabilityService).to receive(:refresh!)
      .and_raise(Stripe::InvalidRequestError.new("The account acct_123 does not exist.", "account"))

    expect { described_class.new.perform(merchant_account.id) }.not_to raise_error
  end

  it "re-raises any other invalid-request error so sidekiq retries it" do
    allow_any_instance_of(StripeConnectPaymentMethodAvailabilityService).to receive(:refresh!)
      .and_raise(Stripe::InvalidRequestError.new("Invalid array", "capabilities"))

    expect { described_class.new.perform(merchant_account.id) }.to raise_error(Stripe::InvalidRequestError)
  end
end
