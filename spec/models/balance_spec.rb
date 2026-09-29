# frozen_string_literal: true

require "spec_helper"

describe Balance do
  let(:user) { create(:user) }
  let(:merchant_account) { create(:merchant_account, user:) }

  describe "validate_amounts_are_only_changed_when_unpaid" do
    let(:balance) { create(:balance, user:, merchant_account:, date: Date.today) }

    describe "new balance" do
      it "allows the balance creation without error" do
        balance
      end
    end

    describe "updating balance's amounts and is unpaid" do
      it "allows the balance's amounts to be updated" do
        balance.increment(:amount_cents, 1000)
        balance.save!
      end
    end

    describe "updating balance's amounts and is processing" do
      before do
        balance.mark_processing!
        balance.increment(:amount_cents, 1000)
      end

      it "raises an error if save! is called with the amount changed" do
        expect { balance.save! }.to raise_error(ActiveRecord::RecordInvalid, /Amount cents may not be changed in processing state/)
      end
    end

    describe "updating balance's amounts and is paid" do
      before do
        balance.mark_processing!
        balance.mark_paid!
        balance.increment(:amount_cents, 1000)
      end

      it "does not allow the balance's amounts to be updated" do
        expect { balance.save! }.to raise_error(ActiveRecord::RecordInvalid, /Amount cents may not be changed in paid state/)
      end
    end

    describe "updating balance's amounts and was paid then marked unpaid again" do
      before do
        balance.mark_processing!
        balance.mark_paid!
        balance.mark_unpaid!
        balance.increment(:amount_cents, 1000)
      end

      it "allows the balance's amounts to be updated" do
        balance.save!
      end
    end
  end

  describe "forfeited balances" do
    let(:balance) { create(:balance) }

    it "allows the balance to be forfeited" do
      balance.mark_forfeited!
    end
  end

  describe "#state" do
    it "has an initial state of unpaid" do
      expect(Balance.new.state).to eq("unpaid")
    end
  end

  describe "Gumroad-held canonical USD invariant" do
    # Userless = Gumroad-held. The explicit merchant id avoids the gumroad_stripe fixture row.
    let(:gumroad_account) do
      create(:merchant_account, user: nil, currency: Currency::USD,
                                charge_processor_merchant_id: "acct_gumroad_held_#{SecureRandom.hex(6)}")
    end

    # The mislabelled shape found in production, written past the model as the ledger writers did.
    def legacy_eur_balance(state: "unpaid", holding_amount_cents: 1_12)
      balance = create(:balance, user:, merchant_account: gumroad_account, amount_cents: 1_12, state:)
      balance.update_columns(currency: Currency::EUR, holding_currency: Currency::EUR, holding_amount_cents:)
      balance
    end

    it "reports a new non-USD Gumroad-held balance without refusing it" do
      allow(ErrorNotifier).to receive(:notify)

      balance = create(:balance, user:, merchant_account: gumroad_account, currency: Currency::EUR, amount_cents: 1_12)

      expect(balance).to be_persisted
      expect(ErrorNotifier).to have_received(:notify).with(
        "Non-USD Gumroad-held balance created; its payouts will fail with currency_mismatch",
        balance_id: balance.id, merchant_account_id: gumroad_account.id, currency: Currency::EUR, holding_currency: Currency::EUR
      )
    end

    it "keeps the new balance when reporting it fails" do
      allow(ErrorNotifier).to receive(:notify).and_raise("Sentry unavailable")

      balance = create(:balance, user:, merchant_account: gumroad_account, currency: Currency::EUR, amount_cents: 1_12)

      expect(balance.reload).to have_attributes(currency: Currency::EUR, amount_cents: 1_12)
    end

    it "does not report a Stripe-held balance held in its account's own currency" do
      allow(ErrorNotifier).to receive(:notify)

      create(:balance, user:, merchant_account:, currency: Currency::USD, holding_currency: Currency::CAD,
                       amount_cents: 70_00, holding_amount_cents: 95_00)

      expect(ErrorNotifier).to have_received(:notify).exactly(0).times
    end

    it "refuses relabelling a Gumroad-held balance to a non-USD currency" do
      balance = create(:balance, user:, merchant_account: gumroad_account)

      balance.holding_currency = Currency::EUR

      expect(balance).not_to be_valid
      expect(balance.errors[:holding_currency]).to be_present
    end

    it "refuses a relabel that leaves the issued currency non-USD" do
      balance = legacy_eur_balance

      balance.holding_currency = Currency::USD

      expect(balance).not_to be_valid
      expect(balance.errors[:holding_currency]).to be_present
    end

    it "refuses a USD relabel whose payout-side amount disagrees with the seller-facing amount" do
      balance = legacy_eur_balance(holding_amount_cents: 1_25)

      balance.currency = Currency::USD
      balance.holding_currency = Currency::USD

      expect(balance).not_to be_valid
      expect(balance.errors[:holding_amount_cents]).to be_present
    end

    it "refuses a relabel that moves both amounts together" do
      balance = legacy_eur_balance

      balance.assign_attributes(currency: Currency::USD, holding_currency: Currency::USD,
                                amount_cents: 2_00, holding_amount_cents: 2_00)

      expect(balance).not_to be_valid
      expect(balance.errors[:base]).to include("a Gumroad-held relabel may not change amounts")
    end

    it "accepts a label-only relabel to USD" do
      balance = legacy_eur_balance

      balance.update!(currency: Currency::USD, holding_currency: Currency::USD)

      expect(balance.reload).to have_attributes(currency: Currency::USD, holding_currency: Currency::USD,
                                                amount_cents: 1_12, holding_amount_cents: 1_12)
    end

    it "still lets a legacy non-USD Gumroad-held row move through the payout states" do
      balance = legacy_eur_balance(state: "paid", holding_amount_cents: 1_25)

      balance.mark_unpaid!

      expect(balance.reload).to be_unpaid
      expect(balance.holding_currency).to eq(Currency::EUR)
    end

    it "still lets a legacy non-USD Gumroad-held row accrue, since only a relabel is checked" do
      balance = legacy_eur_balance

      balance.increment(:amount_cents, 70)
      balance.increment(:holding_amount_cents, 70)
      balance.save!

      expect(balance.reload.amount_cents).to eq(1_82)
    end

    it "leaves a Stripe-held balance's relabel alone" do
      balance = create(:balance, user:, merchant_account:, amount_cents: 70_00, holding_amount_cents: 70_00)

      balance.update!(holding_currency: Currency::CAD, holding_amount_cents: 95_00)

      expect(balance.reload.holding_currency).to eq(Currency::CAD)
    end
  end
end
