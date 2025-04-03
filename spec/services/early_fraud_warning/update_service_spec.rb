# frozen_string_literal: true

require "spec_helper"

describe EarlyFraudWarning::UpdateService, :vcr do
  let(:processor_transaction_id) { "ch_2O8n7J9e1RjUNIyY1rs9MIRL" }

  describe "for a Purchase" do
    let(:purchase) { create(:purchase, stripe_transaction_id: processor_transaction_id) }
    let!(:dispute) { create(:dispute_formalized, purchase:) }
    let!(:refund) { create(:refund, purchase:) }

    shared_examples_for "creates a new record (with purchase)" do
      it "creates a new record" do
        expect do
          described_class.new(record).perform!
        end.to change(EarlyFraudWarning, :count).by(1)

        expect(record.dispute).to eq(dispute)
        expect(record.purchase).to eq(purchase)
        expect(record.refund).to eq(refund)
        expect(record.fraud_type).to eq("made_with_stolen_card")
        expect(record.actionable).to eq(false)
        expect(record.charge_risk_level).to eq("normal")
        expect(record.processor_created_at).not_to be_nil
        expect(record.resolution).to eq(EarlyFraudWarning::RESOLUTION_UNKNOWN)
      end
    end

    shared_examples_for "updates the record (with purchase)" do
      it "updates the record" do
        expect(record.purchase).to eq(purchase)
        expect(record.dispute).to be_nil
        expect(record.refund).to be_nil
        expect(record.actionable).to be(true)

        described_class.new(record).perform!

        expect(record.purchase).to eq(purchase)
        expect(record.dispute).to eq(dispute)
        expect(record.refund).to eq(refund)
        expect(record.fraud_type).to eq("made_with_stolen_card")
        expect(record.actionable).to eq(false)
        expect(record.charge_risk_level).to eq("normal")
      end
    end

    context "when the record is resolved" do
      let!(:record) do
        create(
          :early_fraud_warning,
          purchase:,
          actionable: false,
          resolved_at: Time.current,
          resolution: EarlyFraudWarning::RESOLUTION_RESOLVED_IGNORED
        )
      end

      it "raises error" do
        expect do
          described_class.new(record).perform!
        end.to raise_error(EarlyFraudWarning::UpdateService::AlreadyResolvedError)
      end
    end

    context "when the purchase belongs to a Stripe Connect account" do
      let(:merchant_account) { create(:merchant_account_stripe_connect, charge_processor_merchant_id: "acct_1O9tZ6GFgEK9GGWT") }
      let(:purchase) { create(:purchase, merchant_account:) }
      let!(:dispute) { create(:dispute, purchase:) }
      let!(:refund) { create(:refund, purchase:) }

      before do
        expect(Stripe::Radar::EarlyFraudWarning).to(
          receive(:retrieve)
            .with(
              { id: record.processor_id, expand: %w(charge) },
              { stripe_account: merchant_account.charge_processor_merchant_id },
            )
            .and_call_original
        )
      end

      context "when the record is not yet persisted" do
        let(:record) { EarlyFraudWarning.new(processor_id: "issfr_1O9ttzGFgEK9GGWTiwPNm9WO", purchase:) }

        it_behaves_like "creates a new record (with purchase)"
      end

      context "when the record is persisted" do
        let(:record) do
          create(
            :early_fraud_warning,
            processor_id: "issfr_1O9ttzGFgEK9GGWTiwPNm9WO",
            purchase:,
          )
        end

        it_behaves_like "updates the record (with purchase)"
      end
    end

    context "when the purchase does not belong to a Stripe Connect account" do
      let(:record) { EarlyFraudWarning.new(processor_id: "issfr_0O8n7K9e1RjUNIyYmTbvMMLa", purchase:) }

      before do
        expect(Stripe::Radar::EarlyFraudWarning).to(
          receive(:retrieve)
            .with({ id: record.processor_id, expand: %w(charge) })
            .and_call_original
        )
      end

      context "when the record is not yet persisted" do
        it_behaves_like "creates a new record (with purchase)"
      end

      context "when the record is persisted" do
        let(:record) do
          create(
            :early_fraud_warning,
            processor_id: "issfr_0O8n7K9e1RjUNIyYmTbvMMLa",
            purchase:,
          )
        end

        it_behaves_like "updates the record (with purchase)"
      end
    end
  end

  describe "for a Charge", :vcr do
    let(:purchase) { create(:purchase, stripe_transaction_id: processor_transaction_id) }
    let(:charge) { create(:charge, processor_transaction_id:, purchases: [purchase]) }
    let!(:dispute) { create(:dispute_formalized, purchase: nil, charge:) }
    let!(:refund) { create(:refund, purchase:) }

    shared_examples_for "creates a new record (with charge)" do
      it "creates a new record" do
        expect do
          described_class.new(record).perform!
        end.to change(EarlyFraudWarning, :count).by(1)

        expect(record.dispute).to eq(dispute)
        expect(record.charge).to eq(charge)
        expect(record.refund).to eq(refund)
        expect(record.fraud_type).to eq("made_with_stolen_card")
        expect(record.actionable).to eq(false)
        expect(record.charge_risk_level).to eq("normal")
        expect(record.processor_created_at).not_to be_nil
        expect(record.resolution).to eq(EarlyFraudWarning::RESOLUTION_UNKNOWN)
      end
    end

    shared_examples_for "updates the record (with charge)" do
      it "updates the record" do
        expect(record.charge).to eq(charge)
        expect(record.dispute).to be_nil
        expect(record.refund).to be_nil
        expect(record.actionable).to be(true)

        described_class.new(record).perform!

        expect(record.charge).to eq(charge)
        expect(record.dispute).to eq(dispute)
        expect(record.refund).to eq(refund)
        expect(record.fraud_type).to eq("made_with_stolen_card")
        expect(record.actionable).to eq(false)
        expect(record.charge_risk_level).to eq("normal")
      end
    end

    context "when the record is resolved" do
      let!(:record) do
        create(
          :early_fraud_warning,
          purchase: nil,
          charge:,
          actionable: false,
          resolved_at: Time.current,
          resolution: EarlyFraudWarning::RESOLUTION_RESOLVED_IGNORED
        )
      end

      it "raises error" do
        expect do
          described_class.new(record).perform!
        end.to raise_error(EarlyFraudWarning::UpdateService::AlreadyResolvedError)
      end
    end

    context "when the purchase belongs to a Stripe Connect account" do
      let(:merchant_account) { create(:merchant_account_stripe_connect, charge_processor_merchant_id: "acct_1O9tZ6GFgEK9GGWT") }
      let(:purchase) { create(:purchase, merchant_account:) }
      let(:charge) { create(:charge, merchant_account:, purchases: [purchase]) }
      let!(:dispute) { create(:dispute, purchase: nil, charge:) }
      let!(:refund) { create(:refund, purchase:) }

      before do
        expect(Stripe::Radar::EarlyFraudWarning).to(
          receive(:retrieve)
            .with(
              { id: record.processor_id, expand: %w(charge) },
              { stripe_account: merchant_account.charge_processor_merchant_id },
            )
            .and_call_original
        )
      end

      context "when the record is not yet persisted" do
        let(:record) { EarlyFraudWarning.new(processor_id: "issfr_1O9ttzGFgEK9GGWTiwPNm9WO", charge:) }

        it_behaves_like "creates a new record (with charge)"
      end

      context "when the record is persisted" do
        let(:record) do
          create(
            :early_fraud_warning,
            processor_id: "issfr_1O9ttzGFgEK9GGWTiwPNm9WO",
            purchase: nil,
            charge:
          )
        end

        it_behaves_like "updates the record (with charge)"
      end
    end

    context "when the purchase does not belong to a Stripe Connect account" do
      let(:record) { EarlyFraudWarning.new(processor_id: "issfr_0O8n7K9e1RjUNIyYmTbvMMLa", charge:) }

      before do
        expect(Stripe::Radar::EarlyFraudWarning).to(
          receive(:retrieve)
            .with({ id: record.processor_id, expand: %w(charge) })
            .and_call_original
        )
      end

      context "when the record is not yet persisted" do
        it_behaves_like "creates a new record (with charge)"
      end

      context "when the record is persisted" do
        let(:record) do
          create(
            :early_fraud_warning,
            processor_id: "issfr_0O8n7K9e1RjUNIyYmTbvMMLa",
            purchase: nil,
            charge:
          )
        end

        it_behaves_like "updates the record (with charge)"
      end
    end
  end
end
