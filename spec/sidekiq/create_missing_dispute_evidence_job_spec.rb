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
  def stripe_dispute_for(purchase, **attrs)
    create(:dispute_formalized, purchase:,
                                charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                charge_processor_dispute_id: "du_#{SecureRandom.hex(8)}",
                                **attrs)
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

      it "schedules the due-soon reminder for the opened window" do
        described_class.new.perform

        dispute_evidence = dispute.reload.dispute_evidence
        expect(DisputeEvidenceDueSoonReminderJob)
          .to have_enqueued_sidekiq_job(dispute.id)
          .at(dispute_evidence.seller_response_due_at - DisputeEvidence::EVIDENCE_REMINDER_LEAD_TIME)
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

        it "leaves alone a window opened between the comparison and the clear" do
          allow(ErrorNotifier).to receive(:notify)
          formalization_stamped_at = 30.minutes.ago.change(usec: 0)

          # The interleaving the previous example cannot reach: formalization lands after this job
          # has read the stamp it is about to clear. A read-then-write guard would compare the old
          # value, pass, and then wipe a window the seller has already been told about; the
          # compare-and-clear carries the value into the WHERE, so the write matches no row.
          # Raw SQL, because the stub below wraps every relation's update_all.
          allow_any_instance_of(ActiveRecord::Relation).to receive(:update_all).and_wrap_original do |method, *args|
            DisputeEvidence.connection.update(
              DisputeEvidence.sanitize_sql_array(
                ["UPDATE dispute_evidences SET seller_contacted_at = ? WHERE id = ?", formalization_stamped_at, DisputeEvidence.last.id]
              )
            )
            method.call(*args)
          end

          described_class.new.perform

          expect(dispute.reload.dispute_evidence.seller_contacted_at).to eq(formalization_stamped_at)
        end

        it "reports that it left another path's window alone" do
          formalization_stamped_at = 30.minutes.ago.change(usec: 0)
          allow(ContactingCreatorMailer).to receive(:chargeback_notice) do
            DisputeEvidence.last.update!(seller_contacted_at: formalization_stamped_at)
            raise Redis::CannotConnectError
          end

          expect(ErrorNotifier).to receive(:notify).with(/stamped this evidence in the meantime/)

          described_class.new.perform
        end
      end

      it "does not mistake another path's stamp from the same second for its own" do
        # The rescue's compare-and-clear matches on the timestamp, so it must distinguish two
        # stamps written inside one wall-clock second. seller_contacted_at is datetime(6) and both
        # writers stamp with sub-second precision; storing whole seconds instead would alias the
        # two values and let a failed enqueue clear a window belonging to formalization.
        described_class.new.perform
        ours = dispute.reload.dispute_evidence.seller_contacted_at
        expect(ours.usec).not_to eq(0)

        theirs = ours.change(usec: 0)
        expect(theirs.to_i).to eq(ours.to_i)
        expect(
          DisputeEvidence.where(id: dispute.dispute_evidence.id, seller_contacted_at: theirs).count
        ).to eq(0)
      end

      it "does not read the row back before notifying, so a failed read cannot strand the window" do
        # Between the claim committing and the notice being enqueued there is no rescue, so any
        # database call in that stretch strands a stamped window nobody was told about — and a
        # stamped window no longer matches the sweep that would have retried it. The stamp the job
        # needs is the value it claimed with, so nothing has to be read back.
        allow_any_instance_of(DisputeEvidence).to receive(:reload).and_raise(ActiveRecord::ConnectionNotEstablished)

        expect do
          described_class.new.perform
        end.to have_enqueued_mail(ContactingCreatorMailer, :chargeback_notice).with(dispute.id)

        expect(dispute.reload.dispute_evidence.seller_contacted_at).to be_present
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
          allow_any_instance_of(ActiveRecord::Relation).to receive(:update_all).and_raise("boom")
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
        expect(DisputeEvidenceDueSoonReminderJob).not_to have_enqueued_sidekiq_job(dispute.id)
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

      context "and an unresolved evidence record is already there" do
        let!(:dispute_evidence) { create(:dispute_evidence, dispute:, seller_contacted_at: nil) }

        it "resolves it, so it is not reselected every sweep and left unresolved forever" do
          allow(ErrorNotifier).to receive(:notify)

          described_class.new.perform

          # Nothing else would ever resolve this row: FightDisputesJob skips unannounced evidence,
          # and Onetime::ResolveStuckDisputeEvidence only covers terminal dispute states.
          expect(dispute_evidence.reload).to be_resolved
          expect(dispute_evidence.resolution).to eq(DisputeEvidence::RESOLUTION_REJECTED)
          expect(dispute_evidence.error_message).to include("passed before the seller was asked")
          expect(ContactingCreatorMailer).not_to receive(:chargeback_notice)
        end

        it "stops spending a deadline lookup on it on the next sweep" do
          allow(ErrorNotifier).to receive(:notify)
          described_class.new.perform

          expect(Stripe::Dispute).not_to receive(:retrieve)

          described_class.new.perform
        end
      end
    end

    context "when the processor's deadline cannot be read" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { stripe_dispute_for(purchase) }

      before { allow(Stripe::Dispute).to receive(:retrieve).and_raise(Stripe::APIConnectionError.new("boom")) }

      it "defers the dispute rather than opening a window it cannot check against the cutoff" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }
      end

      it "retries on the following sweep once the deadline can be read again" do
        allow(ErrorNotifier).to receive(:notify)
        described_class.new.perform

        stub_processor_deadline(30.days.from_now)

        expect do
          described_class.new.perform
        end.to change { DisputeEvidence.count }.by(1)

        expect(dispute.reload.dispute_evidence.seller_contacted_at).to be_present
      end
    end

    # The backdated window ends 24 real minutes from now: rounding alone reads it as elapsed, and
    # the pre-fix gate took the submit-without-a-statement branch here — sending nothing to the
    # seller who really had usable time.
    context "when the backdated window has a fraction of an hour left" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { stripe_dispute_for(purchase) }

      before { stub_processor_deadline((described_class::DEADLINE_BUFFER + 24.minutes).from_now) }

      it "still asks the seller instead of submitting immediately" do
        expect do
          described_class.new.perform
        end.to have_enqueued_mail(ContactingCreatorMailer, :chargeback_notice).with(dispute.id)

        dispute_evidence = dispute.reload.dispute_evidence
        expect(DisputeEvidence.window_open?(dispute_evidence.seller_contacted_at)).to be(true)
        # Display copy is clamped to agree with the open window, so the notice quotes a usable
        # hour count next to its submit link instead of "0 hours".
        expect(dispute_evidence.hours_left_to_submit_evidence).to eq(1)
        expect(FightDisputeJob.jobs.map { _1["args"] }).not_to include([dispute.id])
      end
    end

    context "when the deadline leaves the seller no usable time" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { stripe_dispute_for(purchase) }

      before { stub_processor_deadline(2.hours.from_now) }

      it "submits straight away instead of waiting for the next hourly sweep" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          described_class.new.perform
        end.to change { DisputeEvidence.count }.by(1)

        # Asking the seller here would promise them a window that ends after the cutoff, and
        # FightDisputesJob's next tick can be an hour away — of two hours remaining.
        expect(FightDisputeJob.jobs.map { _1["args"] }).to include([dispute.id])
      end

      it "does not ask the seller for a statement they have no time to write" do
        allow(ErrorNotifier).to receive(:notify)
        expect(ContactingCreatorMailer).not_to receive(:chargeback_notice)

        described_class.new.perform
      end

      it "still stamps the window, so the hourly job owns the retry if that submission fails" do
        allow(ErrorNotifier).to receive(:notify)

        described_class.new.perform
        dispute_evidence = dispute.reload.dispute_evidence

        # Leaving seller_contacted_at NULL here would make the submission fire-once: the hourly job
        # skips NULL rows, and the next sweep would find the deadline past and retire the dispute.
        # The window is backdated past its own end, so it is elapsed on arrival — no seller time,
        # but FightDisputesJob will keep re-enqueueing until the row resolves.
        expect(dispute_evidence.seller_contacted_at).to be_present
        expect(dispute_evidence.hours_left_to_submit_evidence).not_to be_positive

        FightDisputeJob.jobs.clear
        FightDisputesJob.new.perform
        expect(FightDisputeJob.jobs.map { _1["args"] }).to include([dispute.id])
      end

      it "reports that it is submitting without a seller statement" do
        expect(ErrorNotifier).to receive(:notify).with(/deadline is too close to ask now/)

        described_class.new.perform
      end
    end

    context "when the evidence has already been submitted to the processor" do
      let!(:purchase) { charged_back_purchase }
      # A dispute the processor CAN be asked about, so the Stripe assertion below is about the query
      # filter rather than about processor_deadline's blank-id early return.
      let!(:dispute) { stripe_dispute_for(purchase) }
      let!(:dispute_evidence) do
        create(:dispute_evidence, dispute:, seller_contacted_at: nil, resolved_at: Time.current,
                                  resolution: DisputeEvidence::RESOLUTION_SUBMITTED)
      end

      it "does not re-open a window on a dispute whose evidence is already gone" do
        expect(ContactingCreatorMailer).not_to receive(:chargeback_notice)
        expect(ErrorNotifier).not_to receive(:notify)

        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }

        expect(dispute_evidence.reload.seller_contacted_at).to be_nil
      end

      it "does not even select it, so no processor call is spent on it" do
        expect(Stripe::Dispute).not_to receive(:retrieve)
        expect_any_instance_of(Purchase).not_to receive(:create_dispute_evidence_if_needed!)

        described_class.new.perform
      end
    end

    context "when the evidence is resolved after the sweep has selected it" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { create(:dispute_formalized, purchase:) }
      let!(:dispute_evidence) { create(:dispute_evidence, dispute:, seller_contacted_at: nil) }

      it "does not open a window on it" do
        # find_each batches, so a row selected at the top of the sweep can be submitted and
        # resolved by the time this dispute is reached. The query filter cannot see that; only
        # the claim inside the transaction can.
        allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!) do
          dispute_evidence.update_as_resolved!(resolution: DisputeEvidence::RESOLUTION_SUBMITTED)
          dispute_evidence
        end
        expect(ContactingCreatorMailer).not_to receive(:chargeback_notice)

        described_class.new.perform

        expect(dispute_evidence.reload.seller_contacted_at).to be_nil
      end

      it "does not overwrite a window formalization opened while the sweep was running" do
        allow(ErrorNotifier).to receive(:notify)
        formalization_stamped_at = 30.minutes.ago.change(usec: 0)

        # Formalization stamps the row after this job read it. A check-then-write would compare the
        # stale NULL, pass, and replace a live 72-hour window the seller was already told about with
        # a backdated one — submitting before the time they were promised. The claim carries
        # seller_contacted_at: nil into the WHERE, so the write matches no row.
        allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!) do
          DisputeEvidence.connection.update(
            DisputeEvidence.sanitize_sql_array(
              ["UPDATE dispute_evidences SET seller_contacted_at = ? WHERE id = ?", formalization_stamped_at, dispute_evidence.id]
            )
          )
          dispute_evidence  # deliberately stale: this is the object production would hold too
        end
        expect(ContactingCreatorMailer).not_to receive(:chargeback_notice)

        described_class.new.perform

        expect(dispute_evidence.reload.seller_contacted_at).to eq(formalization_stamped_at)
      end
    end

    context "when the row this run created cannot have its window opened" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { create(:dispute_formalized, purchase:) }

      before do
        allow_any_instance_of(ActiveRecord::Relation).to receive(:update_all).and_raise("boom")
      end

      it "leaves no half-finished record behind, so the next run can try again" do
        expect(ErrorNotifier).to receive(:notify).with(/could not build evidence for dispute #{dispute.id}/)

        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }

        expect(dispute.reload.dispute_evidence).to be_nil
      end
    end

    context "when the builder hands back a record another path committed" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { create(:dispute_formalized, purchase:) }
      let!(:concurrent_evidence) do
        create(:dispute_evidence, dispute:, seller_contacted_at: nil, reason_for_winning: "Buyer downloaded the file twice.")
      end

      before do
        # Formalization can commit its row in the gap between the sweep reading the association and
        # the builder running, so the row handed back is one this run did not create even though the
        # reads taken beforehand said there was none.
        allow_any_instance_of(Dispute).to receive(:dispute_evidence).and_return(nil)
        allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_return(concurrent_evidence)
        allow_any_instance_of(ActiveRecord::Relation).to receive(:update_all).and_raise("boom")
      end

      it "keeps that record, along with the statement the seller had already put in it" do
        expect(ErrorNotifier).to receive(:notify).with(/could not build evidence for dispute #{dispute.id}/)

        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }

        expect(concurrent_evidence.reload.reason_for_winning).to eq("Buyer downloaded the file twice.")
        expect(concurrent_evidence.seller_contacted_at).to be_nil
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

    context "while formalization is still running" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { stripe_dispute_for(purchase, formalized_side_effects_finished_at: nil) }

      before { stub_processor_deadline(12.hours.from_now) }

      it "leaves the dispute alone while a webhook retry could still finish it" do
        # Formalization stamps the same column and sends its own notice. Within the retry window it
        # is expected to get there, so sweeping now would only duplicate the seller's email.
        expect do
          described_class.new.perform
        end.not_to change { DisputeEvidence.count }
      end

      it "picks it up on the next sweep once the marker is written" do
        described_class.new.perform
        dispute.update!(formalized_side_effects_finished_at: Time.current)

        expect do
          described_class.new.perform
        end.to change { DisputeEvidence.count }.by(1)

        # And the window it opens is still the deadline-aware one, not a fresh 72 hours.
        expect(dispute.reload.dispute_evidence.hours_left_to_submit_evidence).to eq(6)
      end

      it "recovers a formalization abandoned after its webhook retries ran out" do
        # HandleStripeEventWorker gives up after ten retries (~5 hours), and nothing else ever
        # writes the marker. Gating on the marker alone left such a dispute owned by nobody:
        # excluded from this sweep for having no marker, and excluded from FightDisputesJob for
        # having no seller window. It has to be swept once no retry is coming.
        dispute.update!(formalized_at: (described_class::ABANDONED_FORMALIZATION_GRACE + 1.hour).ago)

        expect do
          described_class.new.perform
        end.to change { DisputeEvidence.count }.by(1)

        evidence = dispute.reload.dispute_evidence
        expect(evidence.seller_contacted_at).to be_present
        expect(evidence.hours_left_to_submit_evidence).to eq(6)
      end

      it "recovers an abandoned formalization that never reached its formalized_at stamp" do
        # A crash before mark_formalized! leaves formalized_at NULL, so the grace period has to
        # fall back to the row's own age or the dispute is excluded forever.
        dispute.update!(formalized_at: nil)
        dispute.update_column(:created_at, (described_class::ABANDONED_FORMALIZATION_GRACE + 1.hour).ago)

        expect do
          described_class.new.perform
        end.to change { DisputeEvidence.count }.by(1)
      end

      it "keeps the deadline-aware window when formalization arrives after the recovery sweep" do
        # Both paths claim the window through the same compare-and-claim, so a late formalization
        # cannot replace a backdated 6-hour window with a fresh 72-hour one and push the submission
        # past the processor's cutoff.
        dispute.update!(formalized_at: (described_class::ABANDONED_FORMALIZATION_GRACE + 1.hour).ago)
        described_class.new.perform

        evidence = dispute.reload.dispute_evidence
        expect(evidence.hours_left_to_submit_evidence).to eq(6)

        expect(purchase.create_dispute_evidence_if_needed!.claim_seller_contacted_window!).to be(false)
        expect(evidence.reload.hours_left_to_submit_evidence).to eq(6)
        expect(DisputeEvidence.where(dispute_id: dispute.id).count).to eq(1)
      end
    end

    context "alongside the hourly FightDisputesJob" do
      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { create(:dispute_formalized, purchase:) }
      let!(:dispute_evidence) { create(:dispute_evidence, dispute:, seller_contacted_at: nil) }

      it "owns unannounced evidence: the hourly job leaves it alone until the seller has been asked" do
        allow(ErrorNotifier).to receive(:notify)

        # The order production runs them in: FightDisputesJob is hourly, this sweep is six-hourly,
        # so the hourly job sees the unannounced row first. hours_left_to_submit_evidence is 0 while
        # seller_contacted_at is NULL, which used to read as "window elapsed, submit it".
        FightDisputesJob.new.perform
        expect(FightDisputeJob.jobs.map { _1["args"] }).not_to include([dispute.id])
        expect(dispute_evidence.reload.seller_contacted_at).to be_nil

        described_class.new.perform
        expect(dispute_evidence.reload.seller_contacted_at).to be_present

        # And once the window has elapsed the hourly job picks it up as normal.
        dispute_evidence.update!(seller_contacted_at: 80.hours.ago)
        FightDisputesJob.new.perform
        expect(FightDisputeJob.jobs.map { _1["args"] }).to include([dispute.id])
      end

      it "does not re-ask a seller whose evidence the hourly job has since submitted" do
        allow(ErrorNotifier).to receive(:notify)

        # The failure this ordering used to produce: the hourly job submitted the unannounced row,
        # resolving it, and the next sweep — selecting on a still-NULL seller_contacted_at — emailed
        # the seller a submission window for evidence that had already gone to the processor.
        dispute_evidence.update_as_resolved!(resolution: DisputeEvidence::RESOLUTION_SUBMITTED)

        expect(ContactingCreatorMailer).not_to receive(:chargeback_notice)

        described_class.new.perform

        expect(dispute_evidence.reload.seller_contacted_at).to be_nil
      end
    end

    context "when the mail server permanently rejects the notice" do
      include ActiveJob::TestHelper

      let!(:purchase) { charged_back_purchase }
      let!(:dispute) { stripe_dispute_for(purchase) }

      before do
        allow_any_instance_of(Mail::Message).to receive(:deliver).and_raise(
          Net::SMTPFatalError.new("550 recipient rejected")
        )
        allow(ErrorNotifier).to receive(:notify)
      end

      # RescueSmtpErrors logs the 5xx and returns, so nothing raises in MailDeliveryJob and nothing
      # reaches the rescue above. The window stays stamped with the seller never asked — which is
      # what the stamp handing ownership to FightDisputesJob is for: the statement is lost, the
      # dispute is still fought before the deadline rather than conceded by silence.
      it "keeps the stamped window and still submits the evidence at the deadline" do
        expect do
          perform_enqueued_jobs { described_class.new.perform }
        end.not_to raise_error

        dispute_evidence = dispute.reload.dispute_evidence
        expect(ActionMailer::Base.deliveries).to be_empty
        expect(dispute_evidence.seller_contacted_at).to be_present

        travel_to(dispute_evidence.seller_contacted_at + DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS.hours + 1.hour) do
          expect do
            FightDisputesJob.new.perform
          end.to change { FightDisputeJob.jobs.size }.by(1)
        end
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
