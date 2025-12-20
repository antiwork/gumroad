# frozen_string_literal: true

require "spec_helper"

describe BalanceTopUp do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:credit_card) }
    it { is_expected.to belong_to(:purchase).optional }
    it { is_expected.to belong_to(:credit).optional }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:amount_cents) }
    it { is_expected.to validate_numericality_of(:amount_cents).is_greater_than(0) }
    it { is_expected.to validate_presence_of(:state) }
    it { is_expected.to validate_inclusion_of(:state).in_array(described_class::STATES) }
    it { is_expected.to validate_presence_of(:processor) }
  end

  describe "state machine" do
    let(:balance_top_up) { create(:balance_top_up) }

    describe "initial state" do
      it "starts in pending state" do
        expect(balance_top_up).to be_pending
      end
    end

    describe "#mark_processing" do
      it "transitions from pending to processing" do
        expect(balance_top_up.mark_processing).to be true
        expect(balance_top_up).to be_processing
      end
    end

    describe "#mark_successful" do
      it "transitions from processing to successful" do
        balance_top_up.mark_processing!

        expect(balance_top_up.mark_successful).to be true
        expect(balance_top_up).to be_successful
      end
    end

    describe "#mark_failed" do
      context "when pending" do
        it "transitions to failed" do
          expect(balance_top_up.mark_failed).to be true
          expect(balance_top_up).to be_failed
        end
      end

      context "when processing" do
        it "transitions to failed" do
          balance_top_up.mark_processing!

          expect(balance_top_up.mark_failed).to be true
          expect(balance_top_up).to be_failed
        end
      end
    end
  end

  describe "#formatted_amount" do
    it "formats the amount as USD currency" do
      balance_top_up = build(:balance_top_up, amount_cents: 1500)

      expect(balance_top_up.formatted_amount).to eq("$15")
    end

    it "includes cents when not a whole dollar amount" do
      balance_top_up = build(:balance_top_up, amount_cents: 1550)

      expect(balance_top_up.formatted_amount).to eq("$15.50")
    end
  end

  describe "#successful?" do
    it "returns true when state is successful" do
      balance_top_up = build(:balance_top_up, :successful)

      expect(balance_top_up.successful?).to be true
    end

    it "returns false when state is not successful" do
      balance_top_up = build(:balance_top_up, state: "pending")

      expect(balance_top_up.successful?).to be false
    end
  end

  describe "#failed?" do
    it "returns true when state is failed" do
      balance_top_up = build(:balance_top_up, :failed)

      expect(balance_top_up.failed?).to be true
    end

    it "returns false when state is not failed" do
      balance_top_up = build(:balance_top_up, state: "pending")

      expect(balance_top_up.failed?).to be false
    end
  end
end
