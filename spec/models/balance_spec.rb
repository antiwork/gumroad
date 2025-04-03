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
end
