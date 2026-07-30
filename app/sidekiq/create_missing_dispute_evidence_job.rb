# frozen_string_literal: true

# Backstop for disputes the seller was never asked to defend: either no evidence record was
# built at all, or one was built and the seller was never told about it.
#
# Evidence is normally built the moment a dispute is formalized, inside
# Charge::Disputable#perform_dispute_formalized_side_effects!. That call site is
# best-effort on purpose: create_dispute_evidence_if_needed! can return nil (or one of the
# attached images can fail to generate) without raising, and the dispute is then marked as
# having finished its side effects anyway. When that happens nothing else ever looks at the
# dispute again — FightDisputesJob only claims evidence whose seller window is already open, so
# a dispute with no row, or with a row nobody announced, is invisible to it — and the dispute
# quietly reaches its deadline at the card network with nothing submitted, while the seller is
# never asked for their side of it.
#
# That is not hypothetical: dispute 126682 sat unanswered for 24 days with a live deadline
# and was only found by hand (gumroad-private#1456). This job closes that hole by
# re-attempting the creation on a schedule, so a transient failure at formalization time
# costs a delay rather than the whole dispute.
#
# This job is the sole owner of evidence with no seller window: it either opens the window and
# notifies the seller, or — when the processor's cutoff leaves no usable time — submits straight
# away itself. FightDisputesJob deliberately skips unannounced rows so the two cannot both act
# on one dispute.
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
  # that follows it still lands with time to spare. Below this much time to the cutoff there is
  # no point asking the seller at all.
  DEADLINE_BUFFER = 6.hours

  # Distinguishes "this processor has no deadline for us to read" from "we tried to read the
  # deadline and could not". The second means we cannot tell whether a window we opened would
  # end after the cutoff, so the dispute is deferred to the next sweep rather than given an
  # unverified 72 hours.
  DEADLINE_UNKNOWN = :unknown

  def perform
    # Two shapes of the same gap are swept here, and the second one is why this matches on
    # seller_contacted_at rather than on the evidence row being absent: a dispute with no row
    # at all, and a dispute whose row exists but was never announced to the seller. The
    # second shape happens when an earlier attempt (here or at formalization) created the row
    # and then failed before the notice carrying the submission link went out. Matching on the
    # missing row alone would make that dispute invisible from then on — the row exists, so it
    # would be filtered out, and the 72-hour window would expire with the seller never asked.
    # A LEFT JOIN with a NULL seller_contacted_at covers both: no row means the column is NULL
    # too. Resolved rows are excluded because their evidence has already gone to the processor
    # (or was rejected), so opening a window would ask the seller for a statement that can no
    # longer change anything — and this job submits such rows itself, so it must not reselect
    # what it already sent.
    Dispute.where(state: OPEN_DISPUTE_STATES)
           .where(event_created_at: LOOKBACK.ago..)
           .left_joins(:dispute_evidence)
           .where(dispute_evidences: { seller_contacted_at: nil, resolved_at: nil })
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
      # Nothing is stamped in either of these cases, so the next sweep still selects the dispute.
      # An unreadable deadline is retried rather than assumed away: any window we opened without
      # it would be an unverified 72 hours that may end after the processor stops accepting
      # evidence.
      return if deadline == DEADLINE_UNKNOWN
      # Past the cutoff there is nothing left to submit, and asking the seller for a statement
      # would be asking about a dispute that is already over.
      return if deadline&.past?

      window_start = seller_window_start(deadline)

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
          # Another path reached this row between the query and here.
          return if dispute_evidence.seller_contacted? || dispute_evidence.resolved?

          # Stamping seller_contacted_at opens the window the seller has to add their own
          # statement, and it is also what schedules the submission: FightDisputesJob submits
          # once the window has elapsed. window_start is already backdated where the cutoff is
          # nearer than a full window, so that submission lands before the deadline rather than
          # after it, and the seller is quoted the hours they really have rather than 72.
          dispute_evidence.update!(seller_contacted_at: window_start) if window_start
        end
      rescue => e
        # Nothing half-done may be left behind. The sweep re-finds a dispute by a NULL
        # seller_contacted_at, so an unstamped row would still be picked up next run, but a row
        # this run created and could not stamp is better removed than left as a partial record.
        dispute_evidence.destroy if created_here && dispute_evidence&.persisted?
        ErrorNotifier.notify("CreateMissingDisputeEvidenceJob: could not build evidence for dispute #{dispute.id}: #{e.class} #{e.message}")
        return
      end

      # Compare against the persisted value rather than the one we wrote: the column's precision
      # decides what the compare-and-clear below can match on.
      dispute_evidence.reload
      stamped_at = dispute_evidence.seller_contacted_at

      if stamped_at.nil? || !dispute_evidence.hours_left_to_submit_evidence.positive?
        # No usable time is left for the seller to say anything, so submit what we already
        # assembled now. Waiting for FightDisputesJob's next hourly tick can cost an hour of a
        # cutoff measured in hours, and it no longer claims unannounced evidence at all.
        FightDisputeJob.perform_async(dispute.id)
        ErrorNotifier.notify(
          "CreateMissingDisputeEvidenceJob: dispute #{dispute.id} was never asked for evidence and its " \
          "deadline is too close to ask now, so dispute_evidence #{dispute_evidence.id} is being submitted " \
          "without a seller statement. Something failed when the dispute was formalized on " \
          "#{dispute.formalized_at || dispute.created_at}."
        )
        return
      end

      # Re-sending the chargeback notice is what actually gives the seller the link to submit —
      # the notice they got at formalization had no link, because there was no evidence record
      # to link to.
      begin
        ContactingCreatorMailer.chargeback_notice(dispute.id).deliver_later
      rescue => e
        # Enqueueing can fail on its own (Redis unreachable, for instance). Clear the stamp so
        # the sweep sees this dispute again instead of leaving a started window the seller was
        # never told about — a window with no notice is worse than no window.
        #
        # Only clear the window this run opened, and decide that in the write itself. Formalization
        # stamps the same row and sends its own notice, and its check-then-stamp is not atomic
        # against this one, so it can land between our commit and this rescue — including between
        # a read here and a write after it. Clearing another path's stamp would erase a window the
        # seller has already been told about, and the next sweep would re-notify and restart it.
        left_alone = DisputeEvidence.where(id: dispute_evidence.id, seller_contacted_at: stamped_at)
                                    .update_all(seller_contacted_at: nil, updated_at: Time.current)
                                    .zero?
        message = "CreateMissingDisputeEvidenceJob: could not notify the seller for dispute #{dispute.id}: #{e.class} #{e.message}"
        message += ". Another path stamped this evidence in the meantime, so its window was left alone." if left_alone
        ErrorNotifier.notify(message)
        return
      end

      ErrorNotifier.notify(
        "CreateMissingDisputeEvidenceJob: dispute #{dispute.id} was never asked for evidence and has " \
        "now been contacted late (dispute_evidence #{dispute_evidence.id}). Something failed when the " \
        "dispute was formalized on #{dispute.formalized_at || dispute.created_at}."
      )
    end

    # When the seller's window should be treated as having started, or nil when the cutoff leaves
    # them no usable time. Backdating keeps the submission that follows the window inside the
    # cutoff.
    def seller_window_start(deadline)
      return Time.current if deadline.nil?
      return nil if deadline <= Time.current + DEADLINE_BUFFER

      latest_start = deadline - DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS.hours - DEADLINE_BUFFER
      [Time.current, latest_start].min
    end

    # When the processor tells us when it stops accepting evidence, use it. Processors we hold no
    # deadline for return nil; a lookup that failed returns DEADLINE_UNKNOWN so the dispute is
    # retried on the next sweep instead of being given a window we could not check.
    def processor_deadline(dispute)
      return if dispute.charge_processor_dispute_id.blank?
      return unless dispute.charge_processor_id == StripeChargeProcessor.charge_processor_id

      stripe_dispute = Stripe::Dispute.retrieve(dispute.charge_processor_dispute_id)
      due_by = stripe_dispute.evidence_details&.due_by
      due_by && Time.zone.at(due_by)
    rescue => e
      ErrorNotifier.notify("CreateMissingDisputeEvidenceJob: could not read the deadline for dispute #{dispute.id}: #{e.class} #{e.message}")
      DEADLINE_UNKNOWN
    end
end
