# frozen_string_literal: true

require "test_helper"

class ProcessEarlyFraudWarningJobTest < ActiveSupport::TestCase
  self.described_class = ProcessEarlyFraudWarningJob
  self.rspec_metadata = { vcr: true }



  context_ ProcessEarlyFraudWarningJob, :vcr do
    let(:purchase) { create(:purchase, stripe_transaction_id: "ch_2O8n7J9e1RjUNIyY1rs9MIRL") }
    let!(:early_fraud_warning) { create(:early_fraud_warning, purchase:) }

  context_ "#perform" do
  context_ "when the dispute evidence has been resolved" do
        before do
          early_fraud_warning.update_as_resolved!(resolution: EarlyFraudWarning::RESOLUTION_RESOLVED_IGNORED)
        end

  test "does nothing" do
          expect_any_instance_of(EarlyFraudWarning).not_to receive(:update_from_stripe!)
          described_class.new.perform(early_fraud_warning.id)
        end
      end

  context_ "when not actionable" do
        before do
          early_fraud_warning.update!(actionable: false)
          expect_any_instance_of(EarlyFraudWarning).to receive(:update_from_stripe!).and_return(true)
        end

  context_ "when there is no dispute or refund" do
  test "raises an error" do
            expect { described_class.new.perform(early_fraud_warning.id) }.to raise_error("Cannot determine resolution")
          end
        end

  context_ "when there is a refund" do
          let!(:refund) { create(:refund, purchase:) }

          before do
            early_fraud_warning.update!(refund:)
          end

  test "resolves as not actionable refunded" do
            described_class.new.perform(early_fraud_warning.id)
            expect(early_fraud_warning.reload.resolved?).to eq(true)
            expect(early_fraud_warning.resolution).to eq(EarlyFraudWarning::RESOLUTION_NOT_ACTIONABLE_REFUNDED)
          end

  context_ "when there is also a dispute" do
            let!(:dispute) { create(:dispute_formalized, purchase:, created_at: 1.hour.ago) }

            before do
              early_fraud_warning.update!(dispute:)
            end

  test "resolves as not actionable disputed if created before" do
              described_class.new.perform(early_fraud_warning.id)
              expect(early_fraud_warning.reload.resolved?).to eq(true)
              expect(early_fraud_warning.resolution).to eq(EarlyFraudWarning::RESOLUTION_NOT_ACTIONABLE_DISPUTED)
            end
          end
        end
      end

  context_ "actionable" do
        before do
          expect_any_instance_of(EarlyFraudWarning).to receive(:update_from_stripe!).and_return(true)
        end

        shared_examples_for "resolves as ignored" do |resolution_message|
  test "resolves as ignored" do
            described_class.new.perform(early_fraud_warning.id)
            expect(early_fraud_warning.reload.resolved?).to eq(true)
            expect(early_fraud_warning.resolution).to eq(EarlyFraudWarning::RESOLUTION_RESOLVED_IGNORED)
            expect(early_fraud_warning.resolution_message).to eq(resolution_message)
          end
        end

  context_ "refundable for fraud" do
  context_ "when the purchase is refundable for fraud" do
            before do
              expect_any_instance_of(EarlyFraudWarning).to receive(:chargeable_refundable_for_fraud?).and_return(true)
            end

  context_ "when associated with a purchase" do
  test "resolves as refunded for fraud" do
                expect_any_instance_of(Purchase).to receive(:refund_for_fraud_and_block_buyer!).once.with(GUMROAD_ADMIN_ID).and_return(true)
                described_class.new.perform(early_fraud_warning.id)
                expect(early_fraud_warning.reload.resolved?).to eq(true)
                expect(early_fraud_warning.resolution).to eq(EarlyFraudWarning::RESOLUTION_RESOLVED_REFUNDED_FOR_FRAUD)
              end

  test "does not resolve as refunded for fraud when the refund fails" do
                expect_any_instance_of(Purchase).to receive(:refund_for_fraud_and_block_buyer!).once.with(GUMROAD_ADMIN_ID).and_return(false)

                described_class.new.perform(early_fraud_warning.id)

                expect(early_fraud_warning.reload.resolved?).to eq(false)
              end
            end

  context_ "when associated with a charge" do
              let(:another_purchase) { create(:purchase, stripe_transaction_id: "ch_2O8n7J9e1RjUNIyY1rs9MIRL") }
              let(:charge) { create(:charge, processor_transaction_id: "ch_2O8n7J9e1RjUNIyY1rs9MIRL", purchases: [purchase, another_purchase]) }
              let!(:early_fraud_warning) { create(:early_fraud_warning, purchase: nil, charge:) }

  test "resolves as refunded for fraud" do
                expect_any_instance_of(Charge).to receive(:refund_for_fraud_and_block_buyer!).once.with(GUMROAD_ADMIN_ID).and_return(true)
                described_class.new.perform(early_fraud_warning.id)
                expect(early_fraud_warning.reload.resolved?).to eq(true)
                expect(early_fraud_warning.resolution).to eq(EarlyFraudWarning::RESOLUTION_RESOLVED_REFUNDED_FOR_FRAUD)
              end
            end
          end

  context_ "when the purchase is not refundable for fraud" do
            before do
              expect_any_instance_of(EarlyFraudWarning).to receive(:chargeable_refundable_for_fraud?).and_return(false)
            end

            it_behaves_like "resolves as ignored"
          end
        end

  context_ "subscription contactable" do
          let(:purchase) { create(:membership_purchase) }

  context_ "when the purchase is subscription contactable" do
            before do
              expect_any_instance_of(EarlyFraudWarning).to receive(:purchase_for_subscription_contactable?).and_return(true)
              expect_any_instance_of(EarlyFraudWarning).to receive(:chargeable_refundable_for_fraud?).and_return(false)
            end

  test "sends email and resolves as customer contacted" do
              mail_double = double
              allow(mail_double).to receive(:deliver_later)
              expect(CustomerLowPriorityMailer).to receive(
                :subscription_early_fraud_warning_notification
              ).with(purchase.id).and_return(mail_double)

              described_class.new.perform(early_fraud_warning.id)

              expect(early_fraud_warning.reload.resolved?).to eq(true)
              expect(early_fraud_warning.resolution).to eq(EarlyFraudWarning::RESOLUTION_RESOLVED_CUSTOMER_CONTACTED)
            end

  context_ "when there are other purchases that have been contacted" do
              before do
                expect_any_instance_of(EarlyFraudWarning).to receive(
                  :associated_early_fraud_warning_ids_for_subscription_contacted
                ).and_return([123])
              end

              it_behaves_like "resolves as ignored", "Already contacted for EFW id 123"
            end
          end

  context_ "when the purchase is not refundable for fraud" do
            before do
              expect_any_instance_of(EarlyFraudWarning).to receive(:purchase_for_subscription_contactable?).and_return(false)
              expect_any_instance_of(EarlyFraudWarning).to receive(:chargeable_refundable_for_fraud?).and_return(false)
            end

            it_behaves_like "resolves as ignored"
          end
        end
      end
    end
  end
end
