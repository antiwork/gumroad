# frozen_string_literal: true

# Backstop for disputes the seller was never asked to defend: either no evidence record was
# built at all, or one was built and the seller was never told about it.
#
# Evidence is normally built the moment a dispute is formalized, inside
# Charge::Disputable#perform_dispute_formalized_side_effects!. That call site is
# best-effort on purpose: create_dispute_evidence_if_needed! can return nil (or one of the
# attached images can fail to generate) without raising, and the dispute is then marked as
# having finished its side effects anyway. When that happens nothing else ever looks at the
# dispute again — FightDisputesJob only walks existing DisputeEvidence rows, so a dispute
# with no row is invisible to it — and the dispute quietly reaches its deadline at the card
# network with nothing submitted, while the seller is never asked for their side of it.
#
# That is not hypothetical: dispute 126682 sat unanswered for 24 days with a live deadline
# and was only found by hand (gumroad-private#1456). This job closes that hole by
# re-attempting the creation on a schedule, so a transient failure at formalization time
# costs a delay rather than the whole dispute.
class CreateMissingDisputeEvidenceJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low, lock: :until_executed

  # The states a dispute can still be answered in. Won, lost, and closed disputes are already
  # decided, so a missing evidence row on one of those is history rather than something to act
  # on. In practice almost everything this job sees is `formalized`: `created` only exists on
  # unsaved records inside webhook handling, and nothing in the app calls `mark_initiated!`.
  # They are listed anyway so that a dispute in either state could never slip past unanswered.
  OPEN_DISPUTE_STATES = %w[created initiated formalized].freeze

  # How far back to look. Card networks give sellers weeks, not months, to respond, so a
  # dispute older than this is past any deadline we could still meet — and sweeping the whole
  # table would mean emailing sellers about disputes they have long since forgotten. The window
  # is measured on event_created_at (when the processor raised the dispute) because that is the
  # indexed column, and it is the timestamp the deadline actually hangs off.
  LOOKBACK = 60.days

  # Leave the seller's window a little short of the processor's real cutoff, so the submission
  # that follows it still lands with time to spare.
  DEADLINE_BUFFER = 6.hours

  def perform
    # Two shapes of the same gap are swept here, and the second one is why this matches on
    # seller_contacted_at rather than on the evidence row being absent: a dispute with no row
    # at all, and a dispute whose row exists but was never announced to the seller. The
    # second shape happens when an earlier attempt (here or at formalization) created the row
    # and then failed before the notice carrying the submission link went out. Matching on the
    # missing row alone would make that dispute invisible from then on — the row exists, so it
    # would be filtered out, and the 72-hour window would expire with the seller never asked.
    # A LEFT JOIN with a NULL seller_contacted_at covers both: no row means the column is NULL
    # too.
    Dispute.where(state: OPEN_DISPUTE_STATES)
           .where(event_created_at: LOOKBACK.ago..)
           .left_joins(:dispute_evidence)
           .where(dispute_evidences: { seller_contacted_at: nil })
           .find_each do |dispute|
      create_evidence_for(dispute)
    end
  end

  private
    def create_evidence_for(dispute)
      disputable = dispute.disputable
      # Purchases and charges can be disputed; service charges also have disputes but do not
      # carry the dispute-evidence behaviour at all, so there is nothing to build for them.
      return unless disputable.respond_to?(:create_dispute_evidence_if_needed!)

      deadline = processor_deadline(dispute)
      # No time left at the processor means nothing we build could be submitted, and the
      # seller would be asked to write a statement for a dispute that is already over.
      return if deadline&.past?

      # Only a row this run created may be undone on failure. A row that was already there is
      # the never-announced shape, and destroying it would throw away evidence — including any
      # statement or file the seller uploaded — that a later run could still submit.
      created_here = dispute.dispute_evidence.nil?
      dispute_evidence = nil
      begin
        ApplicationRecord.transaction do
          # This re-checks the same conditions the formalization path checks, and returns nil
          # rather than raising where we have no evidence surface at all: PayPal and Stripe
          # Connect disputes. Most evidence-less disputes are exactly those, and for them
          # having no record is the correct state, not a gap to fill. When the row already
          # exists (the never-announced shape above) it is returned as is.
          dispute_evidence = disputable.create_dispute_evidence_if_needed!
          return if dispute_evidence.blank?
          return if dispute_evidence.seller_contacted?

          # Stamping seller_contacted_at opens the window the seller has to add their own
          # statement, and it is also what schedules the submission: FightDisputesJob submits
          # once the window has elapsed. Backdate it when the processor's cutoff is nearer than
          # a full window, so we submit before the deadline instead of after it — the seller is
          # then told the real number of hours they have rather than an optimistic one.
          latest_start = deadline && (deadline - DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS.hours - DEADLINE_BUFFER)
          dispute_evidence.update_as_seller_contacted!
          dispute_evidence.update!(seller_contacted_at: latest_start) if latest_start && latest_start < dispute_evidence.seller_contacted_at
        end
      rescue => e
        # Nothing half-done may be left behind. The sweep re-finds a dispute by a NULL
        # seller_contacted_at, so an unstamped row would still be picked up next run, but a row
        # this run created and could not stamp is better removed than left as a partial record.
        dispute_evidence.destroy if created_here && dispute_evidence&.persisted?
        ErrorNotifier.notify("CreateMissingDisputeEvidenceJob: could not build evidence for dispute #{dispute.id}: #{e.class} #{e.message}")
        return
      end

      # Re-sending the chargeback notice is what actually gives the seller the link to submit —
      # the notice they got at formalization had no link, because there was no evidence record
      # to link to. Only worth sending while they still have time to act on it; when the
      # deadline is too close for that, what we already assembled is submitted without them.
      stamped_at = dispute_evidence.seller_contacted_at
      begin
        ContactingCreatorMailer.chargeback_notice(dispute.id).deliver_later if dispute_evidence.hours_left_to_submit_evidence.positive?
      rescue => e
        # Enqueueing can fail on its own (Redis unreachable, for instance). Clear the stamp so
        # the sweep sees this dispute again instead of leaving a started window the seller was
        # never told about — a window with no notice is worse than no window.
        #
        # Only clear the window this run opened. Formalization stamps the same row and sends its
        # own notice, and its check-then-stamp is not atomic against this one, so it can land
        # between our commit and this rescue. Clearing that stamp would erase a window the
        # seller has already been told about, and the next sweep would re-notify and restart it.
        dispute_evidence.reload
        if dispute_evidence.seller_contacted_at != stamped_at
          ErrorNotifier.notify(
            "CreateMissingDisputeEvidenceJob: could not notify the seller for dispute #{dispute.id}: " \
            "#{e.class} #{e.message}. Another path stamped this evidence in the meantime, so its " \
            "window was left alone."
          )
          return
        end
        dispute_evidence.update_as_not_seller_contacted!
        ErrorNotifier.notify("CreateMissingDisputeEvidenceJob: could not notify the seller for dispute #{dispute.id}: #{e.class} #{e.message}")
        return
      end

      ErrorNotifier.notify(
        "CreateMissingDisputeEvidenceJob: dispute #{dispute.id} was never asked for evidence and has " \
        "now been contacted late (dispute_evidence #{dispute_evidence.id}). Something failed when the " \
        "dispute was formalized on #{dispute.formalized_at || dispute.created_at}."
      )
    end

    # When the processor tells us when it stops accepting evidence, use it. A dispute we cannot
    # read (network trouble, a processor we have no deadline for) falls back to nil, i.e. build
    # the evidence anyway — today it would get nothing at all, so trying is the safer default.
    def processor_deadline(dispute)
      return if dispute.charge_processor_dispute_id.blank?
      return unless dispute.charge_processor_id == StripeChargeProcessor.charge_processor_id

      stripe_dispute = Stripe::Dispute.retrieve(dispute.charge_processor_dispute_id)
      due_by = stripe_dispute.evidence_details&.due_by
      due_by && Time.zone.at(due_by)
    rescue => e
      ErrorNotifier.notify("CreateMissingDisputeEvidenceJob: could not read the deadline for dispute #{dispute.id}: #{e.class} #{e.message}")
      nil
    end
end
