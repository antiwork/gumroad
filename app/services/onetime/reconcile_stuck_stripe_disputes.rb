# frozen_string_literal: true

# Books Stripe dispute outcomes we never recorded, for disputes stuck non-terminal because the
# closing webhook was missed. See gumroad-private#1700.
#
# Stripe retains events for ~30 days and this cohort is over a year old, so event replay heals
# nothing; and 184 of the cohort are LOST at Stripe, so the verdict can never be inferred from age.
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
        row = { dispute_id: dispute.id, state: dispute.state }

        refusal = internal_refusal(dispute)
        if refusal
          stats[:"refused_#{refusal}"] += 1
          report << row.merge(action: "refused", reason: refusal)
          next
        end

        outcome = stripe_outcome(dispute)
        row = row.merge(stripe_status: outcome[:status])

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

        begin
          book!(dispute, outcome)
        rescue => e
          stats[:"failed_#{outcome[:status]}"] += 1
          report << row.merge(action: "failed", error: "#{e.class}: #{e.message}")
          next
        end

        dispute.reload
        if NONTERMINAL_STATES.include?(dispute.state)
          # The handler returned early (it notifies and returns when the disputable is not
          # actually disputed). Booking it as done would put a lie in the audit trail.
          stats[:book_had_no_effect] += 1
          report << row.merge(action: "book_had_no_effect", end_state: dispute.state)
        else
          stats[:"booked_#{outcome[:status]}"] += 1
          report << row.merge(action: "booked", end_state: dispute.state)
        end
      end

      { stats: stats.to_h, report: }
    end

    private
      # Everything that makes a row unbookable on OUR side, checked before we spend a Stripe call.
      def internal_refusal(dispute)
        if dispute.charge.nil? && dispute.purchase.nil?
          # A service_charge dispute has a real disputable, just not one this script can book —
          # ServiceCharge has no handle_event_dispute_won!/lost! and no seller (dispute.rb's own
          # comment). Keep it out of no_disputable so that stat stays a signal for actual data gaps.
          return "unsupported_disputable_type" if dispute.service_charge.present?
          return "no_disputable"
        end

        # The seller-side debit happens in the FORMALIZED side effects. A row that never got
        # there has no debit on our books, so booking WON would credit a debit that never
        # happened and booking LOST would bury an unbooked loss behind a terminal state.
        return "not_formalized_internally" unless dispute.formalized?
        return "formalization_incomplete" if dispute.formalized_side_effects_finished_at.nil?

        # Destination (Gumroad-managed Stripe Connect) charges settle a won dispute through
        # funds_reinstated, which transfers real money back to the creator's account and builds
        # multi-leg flow of funds. Replaying only the internal booking would credit them on paper
        # with nothing behind it.
        return "destination_charge_needs_manual_repair" if destination_charge?(dispute)

        nil
      end

      # A DESTINATION charge is one settled into a seller's own Gumroad-managed Connect account.
      # `is_a_gumroad_managed_stripe_account?` is also true of Gumroad's platform account
      # (user_id nil), which carries ordinary direct charges — the bulk of this cohort and exactly
      # what we are here to book. Require a seller before refusing.
      def destination_charge?(dispute)
        merchant_account = resolve_merchant_account(dispute)
        return false if merchant_account.nil? || merchant_account.is_managed_by_gumroad?

        merchant_account.is_a_gumroad_managed_stripe_account?
      end

      # The Charge owns the Stripe account the dispute actually lives on; a purchase's
      # merchant_account can be blank (nil for older rows) or point at a different account
      # (e.g. an affiliate's) even though it's one of the disputed purchases. Prefer the Charge.
      def resolve_merchant_account(dispute)
        dispute.charge&.merchant_account || disputed_purchases(dispute).first&.merchant_account
      end

      # Only a dispute Stripe considers finished can be booked. `warning_*` and `needs_response`
      # are inquiries and live disputes: `warning_closed` was never withdrawn at Stripe, so the
      # reinstatement check below cannot clear it and it needs a human.
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
        reason = e.message.to_s.include?("No such dispute") ? "not_found_on_account_tried" : "stripe_invalid_request"
        { ok: false, reason: }
      rescue Stripe::StripeError => e
        { ok: false, reason: "stripe_error_#{e.class.name.demodulize.underscore}" }
      end

      def funds_reinstated?(stripe_dispute)
        Array(stripe_dispute.balance_transactions).any? { |transaction| transaction.amount.to_i > 0 }
      end

      def stripe_account_options(dispute)
        merchant_account = resolve_merchant_account(dispute)
        return {} unless merchant_account&.is_a_stripe_connect_account?
        return {} if merchant_account.charge_processor_merchant_id.blank?

        { stripe_account: merchant_account.charge_processor_merchant_id }
      end

      # `Dispute#purchases` returns `[nil]` for a service-charge dispute, so compact before use.
      def disputed_purchases(dispute)
        Array(dispute.purchases).compact.presence || [dispute.purchase].compact
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
          # The lost handler wraps itself; the won one does not, and a raise partway through its
          # per-purchase loop would leave the dispute terminal with some purchases uncredited.
          dispute.with_lock do
            ActiveRecord::Base.transaction { disputable.handle_event_dispute_won!(event) }
          end
        else
          event.type = ChargeEvent::TYPE_DISPUTE_LOST
          dispute.with_lock { disputable.handle_event_dispute_lost!(event) }
        end
      end
  end
end
