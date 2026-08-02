# frozen_string_literal: true

# Books Stripe dispute outcomes we never recorded, for disputes stuck non-terminal because the
# closing webhook was missed. See gumroad-private#1700.
#
# Stripe has already settled these at the processor: every sampled won dispute carries a
# withdrawal AND a reinstatement balance transaction netting to zero, so the disputed money is
# back on the platform balance. What never happened is the internal booking — the seller's credit
# and the buyer's access — which is why sellers are short and buyers are locked out of paid
# products a year later.
#
# Two things this deliberately does NOT do:
#
# 1. It does not replay the original Stripe events. Stripe retains events for ~30 days and this
#    cohort is over a year old; a replay-based repair heals exactly zero rows.
# 2. It does not infer the verdict from age. 35 of 244 sampled disputes are LOST at Stripe, so
#    anything that treated the backlog as uniformly won would credit sellers for money the bank
#    kept.
module Onetime
  class ReconcileStuckStripeDisputes
    NONTERMINAL_STATES = %w[created initiated formalized].freeze

    def self.process(dry_run: true, dispute_ids: nil, limit: nil)
      new.process(dry_run:, dispute_ids:, limit:)
    end

    def process(dry_run: true, dispute_ids: nil, limit: nil)
      stats = Hash.new(0)
      report = []

      scope = Dispute.where(charge_processor_id: StripeChargeProcessor.charge_processor_id,
                            state: NONTERMINAL_STATES)
      scope = scope.where(id: dispute_ids) if dispute_ids.present?
      scope = scope.limit(limit) if limit

      scope.find_each do |dispute|
        stats[:scanned] += 1
        outcome = stripe_outcome(dispute)
        row = { dispute_id: dispute.id, state: dispute.state, stripe_status: outcome[:status] }

        unless outcome[:ok]
          stats[:"refused_#{outcome[:reason]}"] += 1
          report << row.merge(action: "refused", reason: outcome[:reason])
          next
        end

        if dry_run
          stats[:"would_book_#{outcome[:status]}"] += 1
          report << row.merge(action: "would_book")
          next
        end

        book!(dispute, outcome)
        dispute.reload
        stats[:"booked_#{outcome[:status]}"] += 1
        stats[:still_nonterminal] += 1 if NONTERMINAL_STATES.include?(dispute.state)
        report << row.merge(action: "booked", end_state: dispute.state)
      end

      { stats: stats.to_h, report: }
    end

    private
      # Only a dispute Stripe considers finished can be booked. `warning_*` and `needs_response`
      # are live disputes whose webhooks are still coming.
      def stripe_outcome(dispute)
        processor_id = dispute.charge_processor_dispute_id
        return { ok: false, reason: "no_processor_dispute_id" } if processor_id.blank?

        stripe_dispute = Stripe::Dispute.retrieve({ id: processor_id, expand: %w[balance_transactions] },
                                                  stripe_account_options(dispute))
        status = stripe_dispute.status.to_s
        return { ok: false, reason: "not_terminal_at_stripe", status: } unless %w[won lost].include?(status)

        if status == "won" && !funds_reinstated?(stripe_dispute)
          # Won at Stripe but the money is not back on our balance, so crediting the seller would
          # pay out of our own pocket. Needs a human.
          return { ok: false, reason: "won_without_reinstatement", status: }
        end

        { ok: true, status:, stripe_dispute: }
      rescue Stripe::InvalidRequestError => e
        reason = e.message.to_s.include?("No such dispute") ? "unknown_to_stripe" : "stripe_invalid_request"
        { ok: false, reason: }
      end

      def funds_reinstated?(stripe_dispute)
        Array(stripe_dispute.balance_transactions).any? { |transaction| transaction.amount.to_i > 0 }
      end

      def stripe_account_options(dispute)
        merchant_account = disputed_purchases(dispute).first&.merchant_account
        return {} unless merchant_account&.is_a_stripe_connect_account?
        return {} if merchant_account.charge_processor_merchant_id.blank?

        { stripe_account: merchant_account.charge_processor_merchant_id }
      end

      def disputed_purchases(dispute)
        purchases = dispute.purchases.to_a
        purchases.presence || [dispute.purchase].compact
      end

      # Drives the same handlers the webhook would have, so the credit, the access restore and the
      # state transition stay in one place. The flow of funds is built from Stripe's own figures
      # rather than from the purchase, because a won dispute returns what the bank took.
      def book!(dispute, outcome)
        disputable = dispute.charge || dispute.purchase
        event = ChargeEvent.new
        event.charge_processor_id = StripeChargeProcessor.charge_processor_id
        event.charge_event_id = outcome[:stripe_dispute].id
        event.created_at = Time.zone.at(outcome[:stripe_dispute].created)

        if outcome[:status] == "won"
          event.type = ChargeEvent::TYPE_DISPUTE_WON
          event.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(
            outcome[:stripe_dispute].currency, outcome[:stripe_dispute].amount
          )
          disputable.handle_event_dispute_won!(event)
        else
          event.type = ChargeEvent::TYPE_DISPUTE_LOST
          disputable.handle_event_dispute_lost!(event)
        end
      end
  end
end
