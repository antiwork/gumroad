# frozen_string_literal: true

require "spec_helper"

describe StripePayoutRailSetup do
  let(:seller) { create(:user) }
  let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }

  def expect_abandoned(setup, failure_code)
    setup.reload
    expect(setup.state).to eq(described_class::FAILED)
    expect(setup.failure_code).to eq(failure_code)
    expect(setup.merchant_account).not_to be_alive
    expect(setup.bank_account).to be_deleted
    expect(StripeMerchantAccountManager.blocks_new_managed_account?(seller.reload)).to be(false)
  end

  describe ".open_for" do
    it "returns the seller's pending or prepared setup and ignores finished ones" do
      create(:stripe_payout_rail_setup, user: seller, state: described_class::FAILED)
      prepared = create(:stripe_payout_rail_setup, :prepared, user: seller)
      create(:stripe_payout_rail_setup, :prepared, user: create(:user))

      expect(described_class.open_for(seller)).to eq(prepared)
    end
  end

  describe "when the stored Connect row goes away" do
    it "abandons an open setup when the seller disconnects it" do
      setup = create(:stripe_payout_rail_setup, :prepared, user: seller)

      expect(StripeMerchantAccountManager.disconnect(user: seller)).to be_truthy

      expect_abandoned(setup, "connect_removed")
    end

    it "abandons an open setup when Stripe deauthorizes the Connect account" do
      setup = create(:stripe_payout_rail_setup, :prepared, user: seller)

      StripeMerchantAccountManager.handle_stripe_event_account_deauthorized(
        "id" => "evt_synthetic", "type" => "account.application.deauthorized", "account" => connect_account.charge_processor_merchant_id
      )

      expect(connect_account.reload).not_to be_alive
      expect_abandoned(setup, "connect_removed")
    end

    it "leaves the setup alone when Stripe deauthorizes a different account" do
      setup = create(:stripe_payout_rail_setup, :prepared, user: seller)

      StripeMerchantAccountManager.handle_stripe_event_account_deauthorized(
        "id" => "evt_synthetic", "type" => "account.application.deauthorized", "account" => setup.merchant_account.charge_processor_merchant_id
      )

      expect(setup.reload.state).to eq(described_class::PREPARED)
    end
  end

  describe "#abandon! with accounts the setup never recorded" do
    let(:setup) { create(:stripe_payout_rail_setup, user: seller) }

    # Ownership is the tag create_account writes before calling Stripe; set directly here because these
    # are unit controls for the selection, the end-to-end path being in cancel_spec.
    def managed_account(tag: nil, live: false, created_at: Time.current)
      account = create(:merchant_account, user: seller, country: "US", charge_processor_alive_at: (Time.current if live),
                                          charge_processor_merchant_id: "acct_synthetic_#{SecureRandom.hex(4)}", created_at:)
      account.update!(rail_setup_id: tag) if tag
      account
    end

    it "retires its own not-live accounts and leaves every account it does not own" do
      own = managed_account(tag: setup.id.to_s)
      legacy = managed_account(created_at: 1.day.ago)
      untagged_newer = managed_account
      activated = create(:stripe_payout_rail_setup, user: seller, state: described_class::ACTIVATED)
      activated_account = managed_account(tag: activated.id.to_s, live: true)
      activated.update!(merchant_account: activated_account)
      other_owner = managed_account(tag: create(:stripe_payout_rail_setup, user: seller, state: described_class::FAILED).id.to_s)

      expect(setup.abandon!("cancelled_by_staff")).to be(true)

      expect(own.reload).not_to be_alive
      expect(own.charge_processor_merchant_id).to be_present
      [legacy, untagged_newer, activated_account, other_owner].each { expect(_1.reload).to be_alive }
      expect(activated_account.charge_processor_alive?).to be(true)
    end
  end

  describe "#retire_prepared_account!" do
    let(:setup) { create(:stripe_payout_rail_setup, :prepared, user: seller) }
    let(:account) { setup.merchant_account }

    it "retires the not-live account of a setup that has ended, keeping its provider id" do
      setup.update!(state: described_class::FAILED)

      expect(setup.retire_prepared_account!).to be(true)

      expect(account.reload).not_to be_alive
      expect(account.charge_processor_merchant_id).to be_present
      expect(StripeMerchantAccountManager.blocks_new_managed_account?(seller.reload)).to be(false)
    end

    it "keeps the account while the setup is still open" do
      expect(setup.retire_prepared_account!).to be(false)
      expect(account.reload).to be_alive
    end

    it "keeps a live account" do
      setup.update!(state: described_class::FAILED)
      account.update!(charge_processor_alive_at: Time.current)

      expect(setup.retire_prepared_account!).to be(false)
      expect(account.reload).to be_alive
    end

    it "keeps an account another open or activated setup points at" do
      setup.update!(state: described_class::FAILED)
      other = create(:stripe_payout_rail_setup, :prepared, user: seller, merchant_account: account)

      expect(setup.retire_prepared_account!).to be(false)
      other.update!(state: described_class::ACTIVATED)
      expect(setup.retire_prepared_account!).to be(false)
      expect(account.reload).to be_alive
    end

    it "keeps the Connect account and another seller's account" do
      setup.update!(state: described_class::FAILED)

      expect(setup.retire_prepared_account!(connect_account)).to be(false)
      expect(setup.retire_prepared_account!(create(:merchant_account, user: create(:user), charge_processor_alive_at: nil))).to be(false)
      expect(connect_account.reload).to be_alive
    end
  end
end
