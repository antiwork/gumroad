# frozen_string_literal: true

require "spec_helper"

RSpec.describe FrozenInstallmentConfig do
  describe "#initialize" do
    it "stores number of installments and recurrence" do
      config = described_class.new(
        number_of_installments: 3,
        recurrence: "monthly"
      )

      expect(config.number_of_installments).to eq(3)
      expect(config.recurrence).to eq("monthly")
    end
  end

  describe "#calculate_installment_payments" do
    context "when price is evenly divisible" do
      it "returns equal payment amounts" do
        config = described_class.new(
          number_of_installments: 2,
          recurrence: "monthly"
        )

        payments = config.calculate_installment_payments(1000)

        expect(payments).to eq([500, 500])
      end

      it "handles 4 equal installments" do
        config = described_class.new(
          number_of_installments: 4,
          recurrence: "monthly"
        )

        payments = config.calculate_installment_payments(2000)

        expect(payments).to eq([500, 500, 500, 500])
      end
    end

    context "when price is not evenly divisible" do
      it "puts remainder in first installment" do
        config = described_class.new(
          number_of_installments: 3,
          recurrence: "monthly"
        )

        payments = config.calculate_installment_payments(1000)

        expect(payments).to eq([334, 333, 333])
        expect(payments.sum).to eq(1000)
      end

      it "handles odd amounts correctly" do
        config = described_class.new(
          number_of_installments: 3,
          recurrence: "monthly"
        )

        payments = config.calculate_installment_payments(997)

        expect(payments).to eq([333, 332, 332])
        expect(payments.sum).to eq(997)
      end

      it "handles 2 installments with 1 cent remainder" do
        config = described_class.new(
          number_of_installments: 2,
          recurrence: "monthly"
        )

        payments = config.calculate_installment_payments(999)

        expect(payments).to eq([500, 499])
        expect(payments.sum).to eq(999)
      end
    end

    context "with single installment" do
      it "returns full price" do
        config = described_class.new(
          number_of_installments: 1,
          recurrence: "monthly"
        )

        payments = config.calculate_installment_payments(1000)

        expect(payments).to eq([1000])
      end
    end

    context "with different recurrence types" do
      it "calculates correctly for weekly recurrence" do
        config = described_class.new(
          number_of_installments: 4,
          recurrence: "weekly"
        )

        payments = config.calculate_installment_payments(1000)

        expect(payments).to eq([250, 250, 250, 250])
      end

      it "calculates correctly for quarterly recurrence" do
        config = described_class.new(
          number_of_installments: 4,
          recurrence: "quarterly"
        )

        payments = config.calculate_installment_payments(1200)

        expect(payments).to eq([300, 300, 300, 300])
      end
    end

    context "with large amounts" do
      it "handles large dollar amounts" do
        config = described_class.new(
          number_of_installments: 12,
          recurrence: "monthly"
        )

        payments = config.calculate_installment_payments(99_999)

        expect(payments.length).to eq(12)
        expect(payments.sum).to eq(99_999)
        expect(payments.first).to eq(8336) # 8333 + 3 remainder
        expect(payments[1]).to eq(8333)
      end
    end
  end
end
