# frozen_string_literal: true

# Runs Risk::StrandedBuyerRecoveryService over the scan's candidates on a schedule, so recovery
# no longer waits on a human reading the AlertOnBlockedEstablishedBuyersJob report
# (gumroad-private#1902). A job rather than the admin recover endpoint because one recovery's
# history scans can exceed the HTTP edge budget — measured 504s on the two smallest candidates.
#
# Clears live only behind :auto_recover_stranded_buyers; with the flag off every candidate is
# dry-run and the report says what WOULD have cleared, so the rollout can be judged from real
# candidates before any enforcement is removed.
class RecoverStrandedBuyersJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  # Bounds one run's blast radius; the scan re-surfaces whoever is left on the next run.
  MAX_RECOVERIES_PER_RUN = 25

  # Escalations are the run's point — each names a buyer a human decision is holding. Cleared and
  # skipped buyers are counted, not listed.
  MAX_REPORTED_ESCALATIONS = 15

  def perform
    scan = Risk::StrandedBuyerScanService.call
    return if scan[:stranded].empty?

    live = Feature.active?(:auto_recover_stranded_buyers)
    outcomes = scan[:stranded].first(MAX_RECOVERIES_PER_RUN).map { |candidate| recover(candidate, live:) }

    InternalNotificationWorker.perform_async(
      "risk", "Stranded buyer recovery", message_for(outcomes, live:, total: scan[:stranded].size)
    )
  end

  private
    def recover(candidate, live:)
      result = Risk::StrandedBuyerRecoveryService.call(
        email: candidate[:email],
        user_external_id: candidate[:purchaser_external_id],
        dry_run: !live,
      )
      { email: candidate[:email], verdict: result.verdict, reason: result.reason,
        cleared: result.cleared.size, withheld: result.skipped.size }
    rescue Risk::StrandedBuyerRecoveryService::UnsafeClearError,
           Risk::StrandedBuyerRecoveryService::VerificationFailedError => e
      # One buyer's failed clear must not strand the rest of the run; the transaction inside the
      # service already rolled their rows back.
      { email: candidate[:email], verdict: :error, reason: e.message, cleared: 0, withheld: 0 }
    end

    def message_for(outcomes, live:, total:)
      counts = outcomes.group_by { _1[:verdict] }.transform_values(&:size)
      escalations = outcomes.select { _1[:verdict] == :escalate }
      errors = outcomes.select { _1[:verdict] == :error }
      blocks_cleared = outcomes.sum { _1[:cleared] }
      withheld = outcomes.sum { _1[:withheld] }

      [
        "#{live ? "Recovered" : "DRY RUN (auto_recover_stranded_buyers off) — would recover"} " \
          "#{counts[:cleared].to_i} of #{outcomes.size} stranded buyers processed " \
          "(#{total} candidates total): #{blocks_cleared} blocks cleared, #{withheld} withheld for a human, " \
          "#{counts[:skip].to_i} skipped, #{counts[:noop].to_i} no-ops.",
        ("" if escalations.any?),
        *escalations.first(MAX_REPORTED_ESCALATIONS).map { |o| "• ESCALATE #{o[:email]} — authored block, needs a human decision" },
        (escalations.size > MAX_REPORTED_ESCALATIONS ? "…and #{escalations.size - MAX_REPORTED_ESCALATIONS} more escalations." : nil),
        ("" if errors.any?),
        *errors.map { |o| "• ERROR #{o[:email]} — #{o[:reason]}" },
      ].compact.join("\n")
    end
end
