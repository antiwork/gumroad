# frozen_string_literal: true

require "spec_helper"

describe FightDisputeJob do
  describe "#perform" do
    let(:dispute_evidence) { create(:dispute_evidence) }
    let(:dispute) { dispute_evidence.dispute }

    shared_examples_for "submitted dispute evidence" do
      it "fights chargeback" do
        expect_any_instance_of(Purchase).to receive(:fight_chargeback)
        described_class.new.perform(dispute.id)
        expect(dispute_evidence.reload.resolved?).to eq(true)
        expect(dispute_evidence.resolution).to eq(DisputeEvidence::RESOLUTION_SUBMITTED)
      end
    end

    shared_examples_for "does nothing" do
      it "does nothing" do
        expect_any_instance_of(Purchase).not_to receive(:fight_chargeback)
        described_class.new.perform(dispute.id)
      end
    end

    context "when dispute is on a combined charge", :vcr do
      let(:dispute_evidence) { create(:dispute_evidence_on_charge) }

      before do
        dispute_evidence.update_as_not_seller_contacted!
        expect_any_instance_of(Charge).to receive(:fight_chargeback)
      end

      it "submits evidence correctly" do
        described_class.new.perform(dispute.id)

        expect(dispute_evidence.reload.resolved?).to eq(true)
        expect(dispute_evidence.resolution).to eq(DisputeEvidence::RESOLUTION_SUBMITTED)
      end
    end

    context "when the dispute evidence has been resolved" do
      before do
        dispute_evidence.update_as_resolved!(
          resolution: DisputeEvidence::RESOLUTION_SUBMITTED,
          seller_contacted_at: nil
        )
      end

      it_behaves_like "does nothing"
    end

    context "when the dispute evidence has not been submitted" do
      context "when the seller hasn't been contacted" do
        before do
          dispute_evidence.update_as_not_seller_contacted!
        end

        it_behaves_like "submitted dispute evidence"

        context "when the dispute is already closed" do
          let(:error_message) { "(Status 400) (Request req_OagvpePrZlJtTF) This dispute is already closed" }
          before do
            allow_any_instance_of(Purchase).to receive(:fight_chargeback)
              .and_raise(ChargeProcessorInvalidRequestError.new(error_message))
          end

          it "marks the dispute evidence as rejected" do
            described_class.new.perform(dispute.id)
            expect(dispute_evidence.reload.resolved?).to eq(true)
            expect(dispute_evidence.resolution).to eq(DisputeEvidence::RESOLUTION_REJECTED)
            expect(dispute_evidence.error_message).to eq(error_message)
          end
        end
      end

      context "when the seller has been contacted" do
        context "when the seller has submitted the evidence" do
          before do
            dispute_evidence.update_as_seller_submitted!
          end

          context "when there are still hours left to submit evidence" do
            before do
              dispute_evidence.update_as_seller_contacted!
            end

            it_behaves_like "submitted dispute evidence"
          end

          context "when there are no more hours left to submit evidence" do
            before do
              dispute_evidence.update!(seller_contacted_at: DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS.hours.ago)
            end

            it_behaves_like "submitted dispute evidence"
          end
        end

        context "when the seller has not submitted the evidence" do
          context "when there are still hours left to submit evidence" do
            before do
              dispute_evidence.update_as_seller_contacted!
            end

            it_behaves_like "does nothing"
          end

          context "when there are no more hours left to submit evidence" do
            before do
              dispute_evidence.update!(seller_contacted_at: DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS.hours.ago)
            end

            it_behaves_like "submitted dispute evidence"
          end
        end
      end
    end
  end
end
