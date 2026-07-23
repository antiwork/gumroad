# frozen_string_literal: true

# Backfills the recorded payment method for Stripe purchases paid with a local (non-card)
# method — UPI today, iDEAL when it launches — that completed BEFORE the recording fix
# (#6201) reached production.
#
# Before that fix, a UPI purchase left no queryable trace of its payment method:
#   * `purchases.card_type` ended up nil (server-confirm lane, where the chargeable had no
#     card block) or "generic_card" (client-confirm lane, where the unmapped method type
#     fell through to the unknown-card bucket).
#   * `purchase_payment_flows.stripe_payment_method_type` kept its checkout-time "card"
#     placeholder, because the row is written before the charge exists and nothing
#     corrected it afterwards.
#
# Measuring UPI volume for those purchases required walking Stripe's API by hand. This
# task does that walk once: for every candidate purchase it re-fetches the Stripe charge,
# reads Stripe's own classification of the method (`payment_method_details.type`, exposed
# as StripeCharge#payment_method_type), and corrects both rows — exactly what
# Purchase#save_charge_data now does at charge time for new purchases.
#
# Scope and safety:
#   * Candidates are successful Stripe purchases created in the given window (defaulting
#     to the UPI launch on 2026-07-23) whose card_type is nil or "generic_card" — the two
#     shapes the bug produced. Card purchases recorded correctly and are never selected.
#   * A purchase is only touched when Stripe reports a method that maps to a known
#     CardType other than the unknown-card bucket. A candidate that Stripe says was a
#     plain card (nil card_type has other historical causes) or an unrecognized method
#     keeps its current values, mirroring the fix's own no-"generic_card"-leak rule.
#   * `purchases.card_type` is written with update_column: card_type feeds no search
#     index or callback-driven derivation, and a metrics fix must not require the rest
#     of a possibly-old record to pass today's validations.
#   * Charges are fetched once per Stripe transaction id — purchases in a multi-product
#     order share one combined charge, and every purchase on it has the same method.
#   * Idempotent: re-running skips purchases whose rows already match Stripe.
#
# Dry-run by default:
#
#   Onetime::BackfillStripePaymentMethodTypes.process                 # logs what it would do
#   Onetime::BackfillStripePaymentMethodTypes.process(dry_run: false) # writes
module Onetime
  class BackfillStripePaymentMethodTypes
    BATCH_SIZE = 100

    # The day UPI launched (#6174) — no local-method purchase can predate it.
    DEFAULT_FROM = Time.utc(2026, 7, 23)

    def self.process(dry_run: true, from: DEFAULT_FROM, to: Time.current, batch_size: BATCH_SIZE)
      new(dry_run:, from:, to:, batch_size:).process
    end

    def initialize(dry_run: true, from: DEFAULT_FROM, to: Time.current, batch_size: BATCH_SIZE)
      @dry_run = dry_run
      @from = from
      @to = to
      @batch_size = batch_size
      @stats = Hash.new(0)
      @charge_cache = {}
    end

    def process
      candidates.find_each(batch_size: @batch_size) do |purchase|
        ReplicaLagWatcher.watch
        backfill(purchase)
      rescue => e
        @stats[:errors] += 1
        Rails.logger.error("[BackfillStripePaymentMethodTypes] purchase=#{purchase.id} error=#{e.class}: #{e.message}")
      end

      @stats[:dry_run] = @dry_run
      Rails.logger.info("[BackfillStripePaymentMethodTypes] #{@stats.to_h}")
      @stats
    end

    private
      def candidates
        Purchase
          .where(purchase_state: "successful", charge_processor_id: StripeChargeProcessor.charge_processor_id)
          .where.not(stripe_transaction_id: nil)
          .where(card_type: [nil, CardType::UNKNOWN])
          .where(created_at: @from..@to)
      end

      def backfill(purchase)
        method_type = payment_method_type_for(purchase)
        return tick(:skipped_no_method_type) if method_type.blank?

        mapped_card_type = StripeCardType.to_new_card_type(method_type)
        # Only known local methods get written. A candidate Stripe classifies as "card"
        # was nil/generic for some other historical reason, and an unrecognized method
        # must not be collapsed into "generic_card" (same rule as the charge-time fix).
        return tick(:skipped_not_local_method) if mapped_card_type == CardType::UNKNOWN

        # Both corrections happen in one transaction so a purchase can never end up
        # half-fixed. Without this, a failure writing the payment-flow row AFTER
        # card_type was already corrected would drop the purchase out of the candidate
        # scope (its card_type is no longer nil/generic), leaving the flow row stuck at
        # its "card" placeholder with no rerun able to repair it.
        #
        # The fix methods return the stat key describing what happened instead of
        # counting it themselves: incrementing inside the transaction would leave the
        # in-memory stats claiming a write that the rollback then undid. Only after the
        # block exits (i.e. the transaction committed) do the outcomes get counted; a
        # raise skips the counting entirely and the caller records the error instead.
        outcomes = []
        ApplicationRecord.transaction do
          outcomes << fix_card_type(purchase, mapped_card_type)
          outcomes << fix_payment_flow(purchase, method_type)
        end
        outcomes.each { |outcome| tick(outcome) }
      end

      def payment_method_type_for(purchase)
        @charge_cache.fetch(purchase.stripe_transaction_id) do
          processor_charge = ChargeProcessor.get_charge(
            purchase.charge_processor_id,
            purchase.stripe_transaction_id,
            merchant_account: purchase.merchant_account,
          )
          @charge_cache[purchase.stripe_transaction_id] = processor_charge&.payment_method_type
        end
      end

      # Each fix_* method returns the stat key for what it did (or would do / skipped);
      # backfill counts the keys only after the surrounding transaction commits.
      def fix_card_type(purchase, mapped_card_type)
        return :card_type_already_set if purchase.card_type == mapped_card_type
        return :would_fix_card_type if @dry_run

        purchase.update_column(:card_type, mapped_card_type)
        :fixed_card_type
      end

      def fix_payment_flow(purchase, method_type)
        flow = purchase.purchase_payment_flow
        return :no_payment_flow_row if flow.nil?
        return :flow_already_set if flow.stripe_payment_method_type == method_type
        return :would_fix_flow if @dry_run

        flow.update!(stripe_payment_method_type: method_type)
        :fixed_flow
      end

      def tick(key)
        @stats[key] += 1
      end
  end
end
