# frozen_string_literal: true

require "spec_helper"

describe InstallmentPlanSnapshot do
  let(:subscription) { create(:subscription) }
  let(:payment_option) { create(:payment_option, subscription: subscription) }

  describe "associations" do
    it "belongs to payment_option" do
      snapshot = build(:installment_plan_snapshot, payment_option: payment_option)
      expect(snapshot.payment_option).to eq(payment_option)
    end
  end

  describe "validations" do
    context "number_of_installments" do
      it "requires presence" do
        snapshot = build(:installment_plan_snapshot, payment_option: payment_option, number_of_installments: nil)
        expect(snapshot).not_to be_valid
        expect(snapshot.errors[:number_of_installments]).to include("can't be blank")
      end

      it "must be greater than 0" do
        snapshot = build(:installment_plan_snapshot, payment_option: payment_option, number_of_installments: 0)
        expect(snapshot).not_to be_valid
        expect(snapshot.errors[:number_of_installments]).to include("must be greater than 0")
      end

      it "must be an integer" do
        snapshot = build(:installment_plan_snapshot, payment_option: payment_option, number_of_installments: 3.5)
        expect(snapshot).not_to be_valid
        expect(snapshot.errors[:number_of_installments]).to include("must be an integer")
      end
    end

    context "recurrence" do
      it "requires presence" do
        snapshot = build(:installment_plan_snapshot, payment_option: payment_option, recurrence: nil)
        expect(snapshot).not_to be_valid
        expect(snapshot.errors[:recurrence]).to include("can't be blank")
      end
    end

    context "total_price_cents" do
      it "requires presence" do
        snapshot = build(:installment_plan_snapshot, payment_option: payment_option, total_price_cents: nil)
        expect(snapshot).not_to be_valid
        expect(snapshot.errors[:total_price_cents]).to include("can't be blank")
      end

      it "must be greater than 0" do
        snapshot = build(:installment_plan_snapshot, payment_option: payment_option, total_price_cents: 0)
        expect(snapshot).not_to be_valid
        expect(snapshot.errors[:total_price_cents]).to include("must be greater than 0")
      end

      it "must be an integer" do
        snapshot = build(:installment_plan_snapshot, payment_option: payment_option, total_price_cents: 100.5)
        expect(snapshot).not_to be_valid
        expect(snapshot.errors[:total_price_cents]).to include("must be an integer")
      end
    end

    context "payment_option uniqueness" do
      it "allows only one snapshot per payment_option" do
        create(:installment_plan_snapshot, payment_option: payment_option)
        duplicate = build(:installment_plan_snapshot, payment_option: payment_option)

        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:payment_option]).to include("has already been taken")
      end
    end

    context "valid snapshot" do
      it "is valid with all required attributes" do
        snapshot = build(:installment_plan_snapshot, payment_option: payment_option)
        expect(snapshot).to be_valid
      end
    end
  end

  describe "#calculate_installment_payment_price_cents" do
    context "when total divides evenly" do
      it "returns equal payments" do
        snapshot = create(:installment_plan_snapshot,
                          payment_option: payment_option,
                          number_of_installments: 3,
                          total_price_cents: 15000)

        payments = snapshot.calculate_installment_payment_price_cents
        expect(payments).to eq([5000, 5000, 5000])
        expect(payments.sum).to eq(15000)
      end
    end

    context "when total has remainder" do
      it "adds remainder to first payment" do
        snapshot = create(:installment_plan_snapshot,
                          payment_option: payment_option,
                          number_of_installments: 3,
                          total_price_cents: 10000)

        payments = snapshot.calculate_installment_payment_price_cents
        expect(payments).to eq([3334, 3333, 3333])
        expect(payments.sum).to eq(10000)
      end

      it "handles larger remainders correctly" do
        snapshot = create(:installment_plan_snapshot,
                          payment_option: payment_option,
                          number_of_installments: 3,
                          total_price_cents: 14700)

        payments = snapshot.calculate_installment_payment_price_cents
        expect(payments).to eq([4900, 4900, 4900])
        expect(payments.sum).to eq(14700)
      end
    end

    context "single installment" do
      it "returns full amount" do
        snapshot = create(:installment_plan_snapshot,
                          payment_option: payment_option,
                          number_of_installments: 1,
                          total_price_cents: 10000)

        payments = snapshot.calculate_installment_payment_price_cents
        expect(payments).to eq([10000])
      end
    end

    context "many installments" do
      it "handles 12 installments correctly" do
        snapshot = create(:installment_plan_snapshot,
                          payment_option: payment_option,
                          number_of_installments: 12,
                          total_price_cents: 12000)

        payments = snapshot.calculate_installment_payment_price_cents
        expect(payments).to eq([1000] * 12)
        expect(payments.sum).to eq(12000)
      end
    end
  end
end
