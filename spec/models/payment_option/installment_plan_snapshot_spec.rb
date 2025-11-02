# frozen_string_literal: true

require "spec_helper"

describe "PaymentOption installment plan snapshots" do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 14700) }
  let(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: 3, recurrence: "monthly") }
  let(:subscription) { create(:subscription, link: product, user: seller) }
  let(:payment_option) { create(:payment_option, subscription: subscription, installment_plan: installment_plan) }

  describe "association" do
    it "has one installment_plan_snapshot" do
      expect(payment_option).to respond_to(:installment_plan_snapshot)
    end

    it "can build an installment_plan_snapshot" do
      snapshot = payment_option.build_installment_plan_snapshot(
        number_of_installments: 3,
        recurrence: "monthly",
        total_price_cents: 14700
      )

      expect(snapshot).to be_a(InstallmentPlanSnapshot)
      expect(snapshot.payment_option).to eq(payment_option)
      expect(snapshot.number_of_installments).to eq(3)
      expect(snapshot.recurrence).to eq("monthly")
      expect(snapshot.total_price_cents).to eq(14700)
    end
  end

  describe "snapshot creation" do
    it "creates snapshot with correct attributes" do
      payment_option.build_installment_plan_snapshot(
        number_of_installments: installment_plan.number_of_installments,
        recurrence: installment_plan.recurrence,
        total_price_cents: 14700
      )
      payment_option.save!

      snapshot = payment_option.installment_plan_snapshot
      expect(snapshot).to be_present
      expect(snapshot.number_of_installments).to eq(3)
      expect(snapshot.recurrence).to eq("monthly")
      expect(snapshot.total_price_cents).to eq(14700)
    end
  end

  describe "price protection" do
    let!(:snapshot) do
      create(:installment_plan_snapshot,
             payment_option: payment_option,
             number_of_installments: 3,
             recurrence: "monthly",
             total_price_cents: 14700)
    end

    context "when product price increases" do
      it "maintains original installment amounts" do
        expect(snapshot.total_price_cents).to eq(14700)
        expect(snapshot.number_of_installments).to eq(3)

        payments = snapshot.calculate_installment_payment_price_cents
        expect(payments).to eq([4900, 4900, 4900])
      end
    end

    context "when product price decreases" do
      it "maintains original installment amounts" do
        product.update!(price_cents: 10000)

        snapshot.reload
        expect(snapshot.total_price_cents).to eq(14700)

        payments = snapshot.calculate_installment_payment_price_cents
        expect(payments).to eq([4900, 4900, 4900])
      end
    end
  end

  describe "installment configuration protection" do
    let!(:snapshot) do
      create(:installment_plan_snapshot,
             payment_option: payment_option,
             number_of_installments: 3,
             recurrence: "monthly",
             total_price_cents: 14700)
    end

    context "when installment count changes" do
      it "maintains original count when changed from 3 to 2" do
        installment_plan.update!(number_of_installments: 2)

        snapshot.reload
        expect(snapshot.number_of_installments).to eq(3)

        expect(installment_plan.reload.number_of_installments).to eq(2)
      end

      it "maintains original count when changed from 3 to 5" do
        installment_plan.update!(number_of_installments: 5)

        snapshot.reload
        expect(snapshot.number_of_installments).to eq(3)

        expect(installment_plan.reload.number_of_installments).to eq(5)
      end
    end
  end

  describe "backwards compatibility" do
    context "when no snapshot exists" do
      it "can still access installment_plan through payment_option" do
        expect(payment_option.installment_plan_snapshot).to be_nil
        expect(payment_option.installment_plan).to eq(installment_plan)
        expect(payment_option.installment_plan.number_of_installments).to eq(3)
        expect(payment_option.installment_plan.recurrence).to eq("monthly")
      end
    end

    context "when snapshot exists" do
      let!(:snapshot) do
        create(:installment_plan_snapshot,
               payment_option: payment_option,
               number_of_installments: 5,
               recurrence: "weekly",
               total_price_cents: 20000)
      end

      it "can access both snapshot and live plan" do
        expect(payment_option.installment_plan_snapshot.number_of_installments).to eq(5)
        expect(payment_option.installment_plan_snapshot.recurrence).to eq("weekly")

        expect(payment_option.installment_plan.number_of_installments).to eq(3)
        expect(payment_option.installment_plan.recurrence).to eq("monthly")
      end
    end
  end
end
