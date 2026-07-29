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

  # States a dispute can still be answered in. Won/lost/closed disputes are decided, so a
  # missing evidence row there is history rather than something to act on.
  OPEN_DISPUTE_STATES = %w[created initiated formalized].freeze

  # How far back to look. Card networks give sellers weeks, not months, to respond, so a
  # dispute older than this is past any deadline we could still meet — and sweeping the
  # whole table would mean emailing sellers about disputes they have long since forgotten.
  LOOKBACK = 60.days

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
           .where(created_at: LOOKBACK.ago..)
           .left_joins(:dispute_evidence)
           .where(dispute_evidences: { seller_contacted_at: nil })
           .find_each do |dispute|
      create_evidence_for(dispute)
    end
  end

  private
    def create_evidence_for(dispute)
      disputable = dispute.disputable
      return if disputable.nil?

      # This re-checks the same conditions the formalization path checks, and returns nil
      # rather than raising for the cases where we have no evidence surface at all: PayPal
      # and Stripe Connect disputes. Most evidence-less disputes are exactly those, and for
      # them having no record is the correct state, not a gap to fill. When the row already
      # exists (the never-announced shape above) it is returned as is.
      dispute_evidence = disputable.create_dispute_evidence_if_needed!
      return if dispute_evidence.blank?
      return if dispute_evidence.seller_contacted?

      # Stamping seller_contacted_at starts the 72-hour window the seller has to add their
      # own statement, and re-sending the chargeback notice is what actually gives them the
      # link to do it — the notice they got at formalization had no link, because there was
      # no evidence record to link to. The stamp has to come first because the mailer only
      # renders that link for an evidence record that is already marked as seller-contacted.
      dispute_evidence.update_as_seller_contacted!
      begin
        ContactingCreatorMailer.chargeback_notice(dispute.id).deliver_later
      rescue => e
        # Enqueueing can fail on its own (Redis unreachable, for instance). Clear the stamp
        # so the sweep sees this dispute again instead of leaving a started window the seller
        # was never told about — a window with no notice is worse than no window.
        dispute_evidence.update_as_not_seller_contacted!
        raise e
      end

      ErrorNotifier.notify(
        "CreateMissingDisputeEvidenceJob: dispute #{dispute.id} was never asked for evidence and has " \
        "now been contacted late (dispute_evidence #{dispute_evidence.id}). Something failed when the " \
        "dispute was formalized on #{dispute.formalized_at || dispute.created_at}."
      )
    rescue => e
      # One unbuildable dispute must not stop the sweep from reaching the others. Swallowing the
      # error is safe because nothing half-done is left behind: any dispute that failed before
      # its notice went out still has a NULL seller_contacted_at, so the next sweep retries it.
      ErrorNotifier.notify("CreateMissingDisputeEvidenceJob: failed to create evidence for dispute #{dispute.id}: #{e.class} #{e.message}")
    end
end
