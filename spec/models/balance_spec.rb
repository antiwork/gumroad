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

  describe "Gumroad-held USD invariant" do
    let(:gumroad_account) { MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) }

    it "refuses a Gumroad-held balance with a non-USD holding currency" do
      balance = build(:balance, merchant_account: gumroad_account, currency: Currency::EUR, holding_currency: Currency::EUR)
      expect(balance).not_to be_valid
      expect(balance.errors[:holding_currency]).to include("must be usd for Gumroad-held funds")
    end

    it "refuses a Gumroad-held USD balance whose holding amount differs from its amount" do
      balance = build(:balance, merchant_account: gumroad_account, amount_cents: 10_00, holding_amount_cents: 9_00)
      expect(balance).not_to be_valid
      expect(balance.errors[:holding_amount_cents]).to include("must equal amount_cents for Gumroad-held funds")
    end

    it "accepts a connected account's own-currency balance" do
      connected = create(:merchant_account, user: create(:user), currency: Currency::CAD)
      balance = build(:balance, merchant_account: connected, currency: Currency::USD, amount_cents: 10_00,
                                holding_currency: Currency::CAD, holding_amount_cents: 13_00)
      expect(balance).to be_valid
    end

    it "still lets a legacy non-USD Gumroad-held balance change state, so payouts and repairs are not wedged" do
      balance = writing_legacy_gumroad_held_rows do
        create(:balance, merchant_account: gumroad_account, currency: Currency::EUR, holding_currency: Currency::EUR)
      end
      expect { balance.mark_processing! }.not_to raise_error
      expect(balance.reload.state).to eq("processing")
    end

    it "refuses a further amount change on a legacy non-USD Gumroad-held balance" do
      balance = writing_legacy_gumroad_held_rows do
        create(:balance, merchant_account: gumroad_account, currency: Currency::EUR, holding_currency: Currency::EUR)
      end
      balance.increment(:amount_cents, 1).increment(:holding_amount_cents, 1)
      expect(balance.save).to eq(false)
    end
  end
end
