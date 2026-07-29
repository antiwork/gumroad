# frozen_string_literal: true

require "spec_helper"

describe CreateMissingDisputeEvidenceJob do
  # The real evidence builder screenshots the receipt page with headless Chrome. That is not
  # what this job is about, so stub the screenshot and let the rest of the creation path run.
  before do
    allow(DisputeEvidence::GenerateReceiptImageService).to receive(:perform).and_return(
      File.binread(Rails.root.join("spec", "support", "fixtures", "smilie.png"))
    )
  end

  def charged_back_purchase
    create(:purchase).tap { _1.update_column(:chargeback_date, Time.current) }
  end

  describe "#perform" do
    context "when an open dispute has no evidence record" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { create(:dispute_formalized, purchase:) }

      it "creates the evidence and stamps the seller-contacted window" do
        expect do
          described_class.new.perform
        end.to change { dispute.reload.dispute_evidence }.from(nil)

        dispute_evidence = dispute.reload.dispute_evidence
        expect(dispute_evidence.seller_contacted_at).to be_present
        expect(dispute_evidence.customer_email).to eq(purchase.email)
      end

      it "re-sends the chargeback notice, which is what carries the submission link" do
        expect do
          described_class.new.perform
        end.to have_enqueued_mail(ContactingCreatorMailer, :chargeback_notice).with(dispute.id)
      end

      it "reports that the dispute was left without evidence at formalization time" do
        expect(ErrorNotifier).to receive(:notify).with(/dispute #{dispute.id} was never asked for evidence/)

        described_class.new.perform
      end

      context "when enqueueing the notice fails" do
        before do
          allow(ContactingCreatorMailer).to receive(:chargeback_notice).and_raise(Redis::CannotConnectError)
        end

        it "leaves the window unstarted so the next sweep tries again" do
          allow(ErrorNotifier).to receive(:notify)

          described_class.new.perform

          # The evidence row survives, but without a seller-contacted stamp the dispute still
          # matches the sweep — a started 72-hour window the seller was never told about would
          # expire in silence.
          expect(dispute.reload.dispute_evidence).to be_present
          expect(dispute.dispute_evidence.seller_contacted_at).to be_nil
        end

        it "recovers on the following sweep once the notice can be enqueued again" do
          allow(ErrorNotifier).to receive(:notify)
          described_class.new.perform

          allow(ContactingCreatorMailer).to receive(:chargeback_notice).and_call_original

          expect do
            described_class.new.perform
          end.to have_enqueued_mail(ContactingCreatorMailer, :chargeback_notice).with(dispute.id)

          expect(dispute.reload.dispute_evidence.seller_contacted_at).to be_present
        end
      end

      it "is idempotent — a second run does not create a second record or re-stamp the window" do
        described_class.new.perform
        dispute_evidence = dispute.reload.dispute_evidence
        contacted_at = dispute_evidence.seller_contacted_at

        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }

        expect(dispute_evidence.reload.seller_contacted_at).to eq(contacted_at)
      end
    end

    context "when the evidence record exists but the seller was never told about it" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { create(:dispute_formalized, purchase:) }
      let!(:dispute_evidence) { create(:dispute_evidence, dispute:, seller_contacted_at: nil) }

      it "stamps the window and sends the notice without creating a second record" do
        expect do
          described_class.new.perform
        end.to have_enqueued_mail(ContactingCreatorMailer, :chargeback_notice).with(dispute.id)
          .and not_change { DisputeEvidence.count }

        expect(dispute_evidence.reload.seller_contacted_at).to be_present
      end
    end

    context "when the dispute already has an evidence record" do
      let!(:dispute_evidence) { create(:dispute_evidence) }

      it "leaves it alone" do
        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }
      end
    end

    context "when the disputable is not eligible for dispute evidence" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { create(:dispute_formalized, purchase:) }

      before do
        # PayPal and Stripe Connect disputes have no evidence surface at all, so having no
        # record is the correct state for them rather than a gap to fill.
        purchase.update!(charge_processor_id: PaypalChargeProcessor.charge_processor_id)
      end

      it "does not create evidence" do
        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }
      end
    end

    context "when the purchase was never actually charged back" do
      let!(:purchase) { create(:purchase) }
      let!(:dispute) { create(:dispute_formalized, purchase:) }

      it "does not create evidence" do
        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }
      end
    end

    context "when the dispute is already decided" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { create(:dispute_formalized, purchase:) }

      before { dispute.update_column(:state, "won") }

      it "does not create evidence" do
        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }
      end
    end

    context "when the dispute is older than the lookback window" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { create(:dispute_formalized, purchase:) }

      before { dispute.update_column(:created_at, 90.days.ago) }

      it "does not create evidence, because any deadline has long passed" do
        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }
      end
    end

    context "when one dispute cannot be built" do
      let!(:broken_purchase) { charged_back_purchase }
      let!(:broken_dispute) { create(:dispute_formalized, purchase: broken_purchase) }
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { create(:dispute_formalized, purchase:) }

      before do
        allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_wrap_original do |method|
          raise "boom" if method.receiver.id == broken_purchase.id
          method.call
        end
      end

      it "reports it and still handles the rest of the sweep" do
        expect(ErrorNotifier).to receive(:notify).with(/failed to create evidence for dispute #{broken_dispute.id}/)
        allow(ErrorNotifier).to receive(:notify).with(/was never asked for evidence/)

        described_class.new.perform

        expect(dispute.reload.dispute_evidence).to be_present
      end
    end
  end
end
