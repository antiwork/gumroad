# frozen_string_literal: true

require "spec_helper"

describe StripeChargeRadarProcessor, :vcr do
  describe "#handle_event" do
    let(:purchase) { create(:purchase) }

    shared_examples_for "purchase doesn't exist without Stripe Connect" do
      context "when not in production environment" do
        it "does nothing" do
          expect_any_instance_of(EarlyFraudWarning).not_to receive(:update_from_stripe!)
          expect do
            StripeChargeRadarProcessor.handle_event(stripe_params)
          end.not_to change(EarlyFraudWarning, :count)
        end
      end

      context "when in production environment" do
        before do
          allow(Rails.env).to receive(:production?).and_return(true)
        end

        it "raises error" do
          expect_any_instance_of(EarlyFraudWarning).not_to receive(:update_from_stripe!)
          expect do
            StripeChargeRadarProcessor.handle_event(stripe_params)
          end.to raise_error(ActiveRecord::RecordNotFound)
        end
      end
    end

    shared_examples_for "purchase doesn't exist with Stripe Connect" do
      context "when not in production environment" do
        it "does nothing" do
          expect_any_instance_of(EarlyFraudWarning).not_to receive(:update_from_stripe!)
          StripeChargeRadarProcessor.handle_event(stripe_params)
        end
      end

      context "when in production environment" do
        before do
          allow(Rails.env).to receive(:production?).and_return(true)
        end

        it "does nothing" do
          expect_any_instance_of(EarlyFraudWarning).not_to receive(:update_from_stripe!)
          StripeChargeRadarProcessor.handle_event(stripe_params)
        end
      end
    end

    describe "radar.early_fraud_warning.created" do
      context "without Stripe Connect" do
        let(:stripe_params) do
          {
            "id" => "evt_0O8n7L9e1RjUNIyY90W7gkV3",
            "object" => "event",
            "api_version" => "2020-08-27",
            "created" => 1699116878,
            "data" => {
              "object" => {
                "id" => "issfr_0O8n7K9e1RjUNIyYmTbvMMLa",
                "object" => "radar.early_fraud_warning",
                "actionable" => false,
                "charge" => "ch_2O8n7J9e1RjUNIyY1rs9MIRL",
                "created" => 1699116878,
                "fraud_type" => "made_with_stolen_card",
                "livemode" => false,
                "payment_intent" => "pi_2O8n7J9e1RjUNIyY1X7FyY6q"
              }
            },
            "livemode" => false,
            "pending_webhooks" => 8,
            "request" => {
              "id" => "req_2WfpkRMdlbjEkY",
              "idempotency_key" => "82f4bcef-7a1e-4a28-ac2d-2ae4ceb7fcbe"
            },
            "type" => "radar.early_fraud_warning.created"
          }
        end

        describe "for a Purchase" do
          context "when the purchase doesn't exist" do
            it_behaves_like "purchase doesn't exist without Stripe Connect"
          end

          context "when the purchase is found" do
            before do
              purchase.update_attribute(:stripe_transaction_id, stripe_params["data"]["object"]["charge"])
            end

            it "handles the event by creating a new EFW record" do
              expect_any_instance_of(EarlyFraudWarning).to receive(:update_from_stripe!).and_call_original
              expect do
                StripeChargeRadarProcessor.handle_event(stripe_params)
              end.to change(EarlyFraudWarning, :count).by(1)
              early_fraud_warning = EarlyFraudWarning.last
              expect(early_fraud_warning.processor_id).to eq("issfr_0O8n7K9e1RjUNIyYmTbvMMLa")
              expect(early_fraud_warning.purchase).to eq(purchase)
              expect(early_fraud_warning.charge).to be_nil
              expect(ProcessEarlyFraudWarningJob).to have_enqueued_sidekiq_job(early_fraud_warning.id)
            end
          end
        end

        describe "for a Charge" do
          let(:charge) { create(:charge) }

          before do
            charge.purchases << purchase
            charge.update!(processor_transaction_id: stripe_params["data"]["object"]["charge"])
          end

          it "handles the event by creating a new EFW record" do
            expect_any_instance_of(EarlyFraudWarning).to receive(:update_from_stripe!).and_call_original
            expect do
              StripeChargeRadarProcessor.handle_event(stripe_params)
            end.to change(EarlyFraudWarning, :count).by(1)
            early_fraud_warning = EarlyFraudWarning.last
            expect(early_fraud_warning.processor_id).to eq("issfr_0O8n7K9e1RjUNIyYmTbvMMLa")
            expect(early_fraud_warning.purchase).to be_nil
            expect(early_fraud_warning.charge).to eq(charge)
            expect(ProcessEarlyFraudWarningJob).to have_enqueued_sidekiq_job(early_fraud_warning.id)
          end
        end
      end

      context "with Stripe Connect" do
        let(:stripe_params) do
          {
            "id" => "evt_1ODwGzGFgEK9GGWTrZ2dh9EV",
            "object" => "event",
            "account" => "acct_1O9tZ6GFgEK9GGWT",
            "api_version" => "2023-10-16",
            "created" => 1700343713,
            "data" => {
              "object" => {
                "id" => "issfr_1ODwGzGFgEK9GGWT8y4r0PWV",
                "object" => "radar.early_fraud_warning",
                "actionable" => true,
                "charge" => "ch_3ODwGyGFgEK9GGWT1EQ1TzoG",
                "created" => 1700343713,
                "fraud_type" => "made_with_stolen_card",
                "livemode" => false,
                "payment_intent" => "pi_3ODwGyGFgEK9GGWT1oI9Ocjf"
              }
            },
            "livemode" => false,
            "pending_webhooks" => 4,
            "request" => {
              "id" => "req_1Sfh0xoBJ2JwtC",
              "idempotency_key" => "2d4049d4-0485-4d45-8aa9-77cfc317c012"
            },
            "type" => "radar.early_fraud_warning.created"
          }
        end

        context "when the purchase doesn't exist" do
          it_behaves_like "purchase doesn't exist with Stripe Connect"
        end
      end
    end

    describe "radar.early_fraud_warning.updated" do
      context "without Stripe Connect" do
        let!(:stripe_params) do
          {
            "id" => "evt_0O8n869e1RjUNIyYetklSxRz",
            "object" => "event",
            "api_version" => "2020-08-27",
            "created" => 1699116926,
            "data" => {
              "object" => {
                "id" => "issfr_0O8n7K9e1RjUNIyYmTbvMMLa",
                "object" => "radar.early_fraud_warning",
                "actionable" => false,
                "charge" => "ch_2O8n7J9e1RjUNIyY1rs9MIRL",
                "created" => 1699116878,
                "fraud_type" => "made_with_stolen_card",
                "livemode" => false,
                "payment_intent" => "pi_2O8n7J9e1RjUNIyY1X7FyY6q"
              },
              "previous_attributes" => {
                "actionable" => true
              }
            },
            "livemode" => false,
            "pending_webhooks" => 4,
            "request" => {
              "id" => nil,
              "idempotency_key" => nil
            },
            "type" => "radar.early_fraud_warning.updated"
          }
        end

        describe "for a Purchase" do
          let!(:early_fraud_warning) do
            create(
              :early_fraud_warning,
              processor_id: "issfr_0O8n7K9e1RjUNIyYmTbvMMLa",
              purchase:,
              actionable: true
            )
          end

          context "when the purchase doesn't exist" do
            it_behaves_like "purchase doesn't exist without Stripe Connect"
          end

          context "when the purchase is found" do
            before do
              purchase.update_attribute(:stripe_transaction_id, stripe_params["data"]["object"]["charge"])
            end

            it "handles the event without creating a new EFW record" do
              expect_any_instance_of(EarlyFraudWarning).to receive(:update_from_stripe!).and_call_original
              expect do
                StripeChargeRadarProcessor.handle_event(stripe_params)
              end.not_to change(EarlyFraudWarning, :count)
              expect(early_fraud_warning.reload.actionable).to eq(false)
              expect(early_fraud_warning.purchase).to eq(purchase)
              expect(early_fraud_warning.charge).to be_nil
              expect(ProcessEarlyFraudWarningJob).to have_enqueued_sidekiq_job(early_fraud_warning.id)
            end
          end
        end

        describe "for a Charge" do
          let(:charge) { create(:charge) }
          let!(:early_fraud_warning) do
            create(
              :early_fraud_warning,
              processor_id: "issfr_0O8n7K9e1RjUNIyYmTbvMMLa",
              charge:,
              purchase: nil,
              actionable: true
            )
          end

          before do
            charge.purchases << purchase
            charge.update!(processor_transaction_id: stripe_params["data"]["object"]["charge"])
          end

          it "handles the event without creating a new EFW record" do
            expect_any_instance_of(EarlyFraudWarning).to receive(:update_from_stripe!).and_call_original
            expect do
              StripeChargeRadarProcessor.handle_event(stripe_params)
            end.not_to change(EarlyFraudWarning, :count)
            early_fraud_warning = EarlyFraudWarning.last
            expect(early_fraud_warning.reload.actionable).to eq(false)
            expect(early_fraud_warning.purchase).to be_nil
            expect(early_fraud_warning.charge).to eq(charge)
            expect(ProcessEarlyFraudWarningJob).to have_enqueued_sidekiq_job(early_fraud_warning.id)
          end
        end
      end

      context "with Stripe Connect" do
        let(:stripe_params) do
          {
            "id" => "evt_1ODwGzGFgEK9GGWTrZ2dh9EV",
            "object" => "event",
            "account" => "acct_1O9tZ6GFgEK9GGWT",
            "api_version" => "2023-10-16",
            "created" => 1700343713,
            "data" => {
              "object" => {
                "id" => "issfr_1ODwGzGFgEK9GGWT8y4r0PWV",
                "object" => "radar.early_fraud_warning",
                "actionable" => true,
                "charge" => "ch_3ODwGyGFgEK9GGWT1EQ1TzoG",
                "created" => 1700343713,
                "fraud_type" => "made_with_stolen_card",
                "livemode" => false,
                "payment_intent" => "pi_3ODwGyGFgEK9GGWT1oI9Ocjf"
              }
            },
            "livemode" => false,
            "pending_webhooks" => 4,
            "request" => {
              "id" => "req_1Sfh0xoBJ2JwtC",
              "idempotency_key" => "2d4049d4-0485-4d45-8aa9-77cfc317c012"
            },
            "type" => "radar.early_fraud_warning.created"
          }
        end

        context "when the purchase doesn't exist" do
          it_behaves_like "purchase doesn't exist with Stripe Connect"
        end
      end
    end
  end
end
