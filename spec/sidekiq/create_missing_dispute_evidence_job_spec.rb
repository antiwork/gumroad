# frozen_string_literal: true

require "spec_helper"

describe CreateMissingDisputeEvidenceJob do
  # The real evidence builder screenshots the receipt page with headless Chrome, and the
  # deadline lookup calls the processor. Neither is what this job is about, so stub both and
  # let the rest of the creation path run for real.
  before do
    allow(DisputeEvidence::GenerateReceiptImageService).to receive(:perform).and_return(
      File.binread(Rails.root.join("spec", "support", "fixtures", "smilie.png"))
    )
    stub_processor_deadline(30.days.from_now)
  end

  def stub_processor_deadline(time)
    allow(Stripe::Dispute).to receive(:retrieve).and_return(
      double(evidence_details: double(due_by: time&.to_i))
    )
  end

  def charged_back_purchase
    create(:purchase).tap { _1.update_column(:chargeback_date, Time.current) }
  end

  # The deadline lookup only runs for a dispute we can actually identify at the processor.
  def stripe_dispute_for(purchase)
    create(:dispute_formalized, purchase:,
                                charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                charge_processor_dispute_id: "du_#{SecureRandom.hex(8)}")
  end

  describe "#perform" do
    context "when an open dispute has no evidence record" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { create(:dispute_formalized, purchase:) }

      it "creates the evidence and opens the seller's submission window" do
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

        it "leaves a window another path opened in the meantime alone" do
          allow(ErrorNotifier).to receive(:notify)
          # Formalization stamps the same row between our commit and the failed enqueue, and it
          # sends its own notice — clearing that stamp would restart a window the seller has
          # already been told about.
          formalization_stamped_at = 30.minutes.ago.change(usec: 0)
          allow(ContactingCreatorMailer).to receive(:chargeback_notice) do
            DisputeEvidence.last.update!(seller_contacted_at: formalization_stamped_at)
            raise Redis::CannotConnectError
          end

          described_class.new.perform

          expect(dispute.reload.dispute_evidence.seller_contacted_at).to eq(formalization_stamped_at)
        end
      end

      it "is idempotent — a second run does not create a second record, re-open the window, or re-email" do
        described_class.new.perform
        dispute_evidence = dispute.reload.dispute_evidence
        contacted_at = dispute_evidence.seller_contacted_at

        expect do
          expect(ContactingCreatorMailer).not_to receive(:chargeback_notice)
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

      context "when the window cannot be opened" do
        before do
          allow_any_instance_of(DisputeEvidence).to receive(:update_as_seller_contacted!).and_raise("boom")
        end

        it "keeps the record it did not create, so a later run can still submit what the seller uploaded" do
          expect(ErrorNotifier).to receive(:notify).with(/could not build evidence for dispute #{dispute.id}/)

          described_class.new.perform

          expect(dispute_evidence.reload).to be_present
          expect(dispute_evidence.seller_contacted_at).to be_nil
        end
      end
    end

    context "when the processor's deadline is closer than a full submission window" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { stripe_dispute_for(purchase) }

      before { stub_processor_deadline(12.hours.from_now) }

      it "backdates the window so the evidence is submitted before the deadline, and tells the seller the hours they really have" do
        expect do
          described_class.new.perform
        end.to have_enqueued_mail(ContactingCreatorMailer, :chargeback_notice).with(dispute.id)

        dispute_evidence = dispute.reload.dispute_evidence
        expect(dispute_evidence).to be_present
        # FightDisputesJob submits once the window has elapsed, so the window has to end before
        # the processor's cutoff — here 6 hours short of the 12 hours left, not the full 72 the
        # notice would otherwise promise.
        expect(dispute_evidence.hours_left_to_submit_evidence).to eq(6)
        expect(dispute_evidence.seller_contacted_at).to be < Time.current
      end
    end

    context "when the processor's deadline has already passed" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { stripe_dispute_for(purchase) }

      before { stub_processor_deadline(1.day.ago) }

      it "does not build evidence for a dispute that can no longer be answered" do
        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }
      end
    end

    context "when the processor's deadline cannot be read" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { stripe_dispute_for(purchase) }

      before { allow(Stripe::Dispute).to receive(:retrieve).and_raise(Stripe::APIConnectionError.new("boom")) }

      it "still builds the evidence, because doing nothing is the worse default" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          described_class.new.perform
        end.to change { DisputeEvidence.count }.by(1)
      end
    end

    context "when the row this run created cannot have its window opened" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { create(:dispute_formalized, purchase:) }

      before do
        allow_any_instance_of(DisputeEvidence).to receive(:update_as_seller_contacted!).and_raise("boom")
      end

      it "leaves no half-finished record behind, so the next run can try again" do
        expect(ErrorNotifier).to receive(:notify).with(/could not build evidence for dispute #{dispute.id}/)

        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }

        expect(dispute.reload.dispute_evidence).to be_nil
      end
    end

    context "when the dispute already has an evidence record" do
      let!(:dispute_evidence) { create(:dispute_evidence) }

      it "leaves it alone entirely" do
        contacted_at = dispute_evidence.seller_contacted_at
        expect(ContactingCreatorMailer).not_to receive(:chargeback_notice)
        expect(ErrorNotifier).not_to receive(:notify)

        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }

        expect(dispute_evidence.reload.seller_contacted_at).to eq(contacted_at)
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

      it "does not create evidence or notify anybody" do
        expect(ContactingCreatorMailer).not_to receive(:chargeback_notice)
        expect(ErrorNotifier).not_to receive(:notify)

        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }
      end
    end

    context "when the dispute is on a service charge" do
      let!(:dispute) { create(:dispute_formalized, purchase: nil, service_charge: create(:service_charge)) }

      it "skips it, because service charges carry no dispute-evidence behaviour" do
        expect(ErrorNotifier).not_to receive(:notify)

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

      before { dispute.update_column(:event_created_at, 90.days.ago) }

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
        expect(ErrorNotifier).to receive(:notify).with(/could not build evidence for dispute #{broken_dispute.id}/)
        allow(ErrorNotifier).to receive(:notify).with(/was never asked for evidence/)

        described_class.new.perform

        expect(dispute.reload.dispute_evidence).to be_present
      end
    end
  end
end
