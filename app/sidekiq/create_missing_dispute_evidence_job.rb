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
# notifies the seller, or — when the cutoff leaves no usable time — backdates it and submits
# without asking. FightDisputesJob deliberately skips unannounced rows so the two cannot both act
# on one dispute; stamping is what hands ownership back to it.
class CreateMissingDisputeEvidenceJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low, lock: :until_executed
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 1.hour

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

  # Leave the seller's window short of the processor's real cutoff, so the submission that follows
  # it still lands with time to spare — and so the hourly submitter's tick fits inside the margin.
  DEADLINE_BUFFER = 6.hours

  # Distinguishes "this processor has no deadline for us to read" from "we tried and could not".
  # The second defers the dispute rather than giving it an unverified 72 hours.
  DEADLINE_UNKNOWN = :unknown

  # How long a dispute may sit formalized with unfinished side effects before this job takes it
  # anyway. HandleStripeEventWorker carries the resumption (retry: 10, Sidekiq's default backoff)
  # and gives up after roughly five hours, so past this point no retry is coming and nothing else
  # will ever finish that formalization — the marker stays NULL forever. Waiting on the marker
  # alone therefore excluded exactly the disputes that most need the backstop.
  ABANDONED_FORMALIZATION_GRACE = 12.hours

  def perform
    # A NULL seller_contacted_at covers both shapes of the gap — no evidence row at all, and a row
    # whose notice never went out — because a LEFT JOIN reports a missing row as NULL too. Matching
    # on the absent row alone would make the never-announced shape invisible forever. Resolved rows
    # are excluded because this job submits them itself and must not reselect what it already sent.
    #
    # Formalizations still in flight are left to finish: their own path stamps the same column, and
    # a duplicate notice within the retry window is noise the seller does not need. Once the grace
    # period has passed no retry is coming, so the dispute is swept whether the marker was written
    # or not. Racing that path is safe either way, because both open the window through
    # DisputeEvidence#claim_seller_contacted_window! and the loser leaves the winner's window alone.
    Dispute.where(state: OPEN_DISPUTE_STATES)
           .where(event_created_at: LOOKBACK.ago..)
           .where("(disputes.formalized_side_effects_finished_at IS NOT NULL OR COALESCE(disputes.formalized_at, disputes.created_at) < ?)", ABANDONED_FORMALIZATION_GRACE.ago)
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
      # Nothing is stamped, so the next sweep selects this dispute again and reads the cutoff
      # afresh. Opening a window without it would be an unverified 72 hours that may end after the
      # processor stops accepting evidence.
      return if deadline == DEADLINE_UNKNOWN
      # Past the cutoff the processor accepts nothing, so there is no submission left to make and
      # no point asking the seller. Resolve the row instead of leaving it to be reselected every
      # sweep until the lookback ages it out.
      return retire_past_deadline(dispute, deadline) if deadline&.past?

      window_start = seller_window_start(deadline)

      dispute_evidence = nil
      claimed = false
      begin
        ApplicationRecord.transaction do
          # This re-checks the same conditions the formalization path checks, and returns nil
          # rather than raising where we have no evidence surface at all: PayPal and Stripe
          # Connect disputes. Most evidence-less disputes are exactly those, and for them
          # having no record is the correct state, not a gap to fill. When the row already
          # exists (the never-announced shape above) it is returned as is.
          dispute_evidence = disputable.create_dispute_evidence_if_needed!

          if dispute_evidence.present?
            # Stamping seller_contacted_at opens the window the seller has to add their own statement,
            # and it is also what hands the row to FightDisputesJob, which submits once the window has
            # elapsed. window_start is backdated where the cutoff is nearer than a full window, so
            # that submission lands before the deadline rather than after it.
            #
            # claim_seller_contacted_window! is the protocol formalization uses too: the condition is
            # in the WHERE, so whichever path gets there first owns the window and the other writes
            # nothing. Nothing may `return` out of this block — that rolls the transaction back,
            # discarding a concurrent writer's committed work along with our own.
            claimed = dispute_evidence.claim_seller_contacted_window!(at: window_start)
          end
        end
      rescue => e
        # No cleanup here, deliberately. Both the row's creation and its claim run inside the
        # transaction above, so a failure in either rolls the row back on its own. Anything still
        # present once we reach this rescue therefore predates this run — either the
        # never-announced shape, or a row another path committed while we were working — and
        # destroying it would throw away evidence, including any statement or file the seller
        # uploaded, that a later run could still submit. An unstamped row is re-found next sweep.
        ErrorNotifier.notify("CreateMissingDisputeEvidenceJob: could not build evidence for dispute #{dispute.id}: #{e.class} #{e.message}")
        return
      end
      return unless claimed

      # window_start is the persisted stamp: the claim above wrote it and returned that it won, so
      # nothing needs reading back to learn it. It used to be read back, which put a database call
      # in the one stretch that has no rescue — a failure between the commit and the enqueue below
      # left the window stamped with nobody told about it, and a stamped window no longer matches
      # the sweep that would have retried. Nothing here can raise now.
      #
      # Ask through window_open? rather than the record: update_all left this object stale, so it
      # reports no window at all, and the gate has to be the same check the notice quotes. Exact
      # comparison, not the rounded hours, so this cannot close the window up to 29 minutes early.
      unless DisputeEvidence.window_open?(window_start)
        # The backdated window has already elapsed, so the seller has no time to say anything and
        # there is nothing to notify them about. Submit now rather than wait for FightDisputesJob's
        # next tick, which can cost an hour of a cutoff measured in hours — but the window IS
        # stamped, so that job owns the retries if this submission fails.
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
        # SMTP rejections do not arrive here, and cannot: ApplicationMailer includes
        # RescueSmtpErrors, which logs Net::SMTPFatalError and returns, so a permanently rejected
        # notice raises nothing in either delivery path. Such a window stays stamped, which is
        # why the stamp hands ownership to FightDisputesJob — the evidence is still submitted at
        # the deadline, without a seller statement. Formalization's own notice has the same
        # exposure and no rollback at all; closing it means changing where mailers swallow 5xx.
        #
        # Only clear the window this run opened, and decide that in the write itself: carrying the
        # value we claimed with into the WHERE means a stamp belonging to anyone else matches no
        # row. Clearing another path's stamp would erase a window the seller has already been told
        # about, and the next sweep would re-notify and restart it.
        #
        # Nothing can currently own that stamp but us, since both writers go through
        # claim_seller_contacted_window! and its NULL condition makes the loser write nothing — a
        # formalization landing first fails our claim above and we never reach here. The guard
        # stays because it is the cheap half of the invariant, and it does not rest on timestamps
        # being distinct: the column is datetime(6), so two stamps in one second differ anyway.
        left_alone = DisputeEvidence.where(id: dispute_evidence.id, seller_contacted_at: window_start)
                                    .update_all(seller_contacted_at: nil, updated_at: Time.current)
                                    .zero?
        message = "CreateMissingDisputeEvidenceJob: could not notify the seller for dispute #{dispute.id}: #{e.class} #{e.message}"
        message += ". Another path stamped this evidence in the meantime, so its window was left alone." if left_alone
        ErrorNotifier.notify(message)
        return
      end
      DisputeEvidence.schedule_due_soon_reminder(
        dispute_id: dispute.id,
        seller_contacted_at: window_start,
        resolved_at: nil
      )

      ErrorNotifier.notify(
        "CreateMissingDisputeEvidenceJob: dispute #{dispute.id} was never asked for evidence and has " \
        "now been contacted late (dispute_evidence #{dispute_evidence.id}). Something failed when the " \
        "dispute was formalized on #{dispute.formalized_at || dispute.created_at}."
      )
    end

    # When the seller's window should be treated as having started. Always a time, never nil: the
    # stamp is what makes FightDisputesJob the row's owner, so a cutoff too close to give the seller
    # any time backdates the window past its own end rather than leaving the row unclaimed.
    def seller_window_start(deadline)
      return Time.current if deadline.nil?

      latest_start = deadline - DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS.hours - DEADLINE_BUFFER
      [Time.current, latest_start].min
    end

    # A dispute the processor will no longer accept evidence for. Its evidence row would otherwise
    # keep matching the sweep — costing a deadline lookup every six hours — and then sit unresolved
    # forever once the lookback ages the dispute out, since nothing else resolves a row whose dispute
    # never reached a terminal state.
    def retire_past_deadline(dispute, deadline)
      dispute_evidence = dispute.dispute_evidence
      return if dispute_evidence.nil? || dispute_evidence.resolved?

      dispute_evidence.update_as_resolved!(
        resolution: DisputeEvidence::RESOLUTION_REJECTED,
        error_message: "Deadline at the processor (#{deadline.iso8601}) passed before the seller was asked for evidence."
      )
      ErrorNotifier.notify(
        "CreateMissingDisputeEvidenceJob: dispute #{dispute.id} reached its processor deadline with the seller " \
        "never asked for evidence, so dispute_evidence #{dispute_evidence.id} was resolved as rejected."
      )
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
