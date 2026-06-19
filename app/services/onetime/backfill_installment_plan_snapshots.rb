# frozen_string_literal: true

# Freezes the originally-agreed terms of legacy installment-plan subscriptions that predate the
# installment plan snapshot feature. Without a snapshot, each charge recomputes the per-installment
# price from the product's *current* price, installment count, and offer code, so subsequent charges
# drift when the seller edits the product or the offer code is deleted/expired/maxed out (#1410).
#
# This backfills an InstallmentPlanSnapshot (number_of_installments, recurrence, total_price_cents)
# onto the subscription's payment option, reconstructing the agreed discounted total from the cached
# purchase_offer_code_discount on the original purchase — independent of any later price drift. After
# this runs, those subscriptions charge exactly like ones created after the snapshot feature shipped.
#
# Scope: only plans that used a discount code (i.e. have a cached discount) are backfilled — that is
# the population affected by #1410, where deleting the code drops the discount. Legacy plans bought
# without a discount code are intentionally left alone; their price can only drift if the seller
# edits the product price, a separate concern outside this fix.
#
# Idempotent and dry-run by default. Only touches subscriptions that still have charges remaining.
#
#   Onetime::BackfillInstallmentPlanSnapshots.process                 # dry run, logs what it would do
#   Onetime::BackfillInstallmentPlanSnapshots.process(dry_run: false) # writes snapshots
module Onetime
  class BackfillInstallmentPlanSnapshots
    BATCH_SIZE = 1_000

    def self.process(dry_run: true, batch_size: BATCH_SIZE)
      new(dry_run:, batch_size:).process
    end

    def initialize(dry_run: true, batch_size: BATCH_SIZE)
      @dry_run = dry_run
      @batch_size = batch_size
      @stats = Hash.new(0)
    end

    def process
      Subscription.is_installment_plan
        .includes(
          link: :installment_plan,
          original_purchase: :purchase_offer_code_discount,
          last_payment_option: [:installment_plan, :installment_plan_snapshot],
        )
        .find_each(batch_size: @batch_size) do |subscription|
        ReplicaLagWatcher.watch
        backfill(subscription)
      rescue => e
        @stats[:errors] += 1
        Rails.logger.error("[BackfillInstallmentPlanSnapshots] subscription=#{subscription.id} error=#{e.class}: #{e.message}")
      end

      @stats[:dry_run] = @dry_run
      Rails.logger.info("[BackfillInstallmentPlanSnapshots] #{@stats.to_h}")
      @stats
    end

    private
      def backfill(subscription)
        return tick(:skipped_test) if subscription.is_test_subscription?

        payment_option = subscription.last_payment_option
        return tick(:skipped_no_payment_option) if payment_option.nil?
        return tick(:skipped_has_snapshot) if payment_option.installment_plan_snapshot.present?

        number_of_installments = subscription.charge_occurrence_count.to_i
        return tick(:skipped_no_installment_count) if number_of_installments <= 0

        original_purchase = subscription.original_purchase
        return tick(:skipped_no_original_purchase) if original_purchase.nil?

        discount = original_purchase.purchase_offer_code_discount
        return tick(:skipped_no_cached_discount) if discount.nil?

        total_price_cents = agreed_total_cents(original_purchase, discount)
        return tick(:skipped_non_positive_total) if total_price_cents <= 0

        recurrence = payment_option.installment_plan&.recurrence || subscription.link&.installment_plan&.recurrence
        return tick(:skipped_no_recurrence) if recurrence.blank?

        # Counting successful charges is the only remaining per-record query, so it runs last —
        # only for subscriptions that are otherwise fully eligible.
        return tick(:skipped_completed) if subscription.purchases.successful.count >= number_of_installments

        if @dry_run
          Rails.logger.info("[BackfillInstallmentPlanSnapshots] would snapshot subscription=#{subscription.id} " \
                            "total_price_cents=#{total_price_cents} number_of_installments=#{number_of_installments} recurrence=#{recurrence}")
          return tick(:would_create)
        end

        payment_option.create_installment_plan_snapshot!(
          number_of_installments:,
          recurrence:,
          total_price_cents:,
        )
        tick(:created)
      end

      def agreed_total_cents(original_purchase, discount)
        per_unit_before = discount.pre_discount_minimum_price_cents.to_i
        # Reconstruct the cached discount as an OfferCode so the percent/fixed math stays in one
        # place (OfferCode#amount_off). Only the amount is needed, so the deleted code isn't loaded.
        offer_code_attrs = discount.offer_code_is_percent ? { amount_percentage: discount.offer_code_amount } : { amount_cents: discount.offer_code_amount }
        amount_off = OfferCode.new(offer_code_attrs).amount_off(per_unit_before)
        # No Purchasing Power Parity factor: PPP and offer codes are mutually exclusive in pricing
        # (Purchase#minimum_paid_price_cents only applies the PPP factor when no offer code is set),
        # so a plan with a cached discount never had a PPP component in its price.
        [per_unit_before - amount_off, 0].max * (original_purchase.quantity || 1)
      end

      def tick(key)
        @stats[key] += 1
        nil
      end
  end
end
