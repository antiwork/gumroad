# frozen_string_literal: true

# Pauses gp#1410's at-risk memberships up front instead of waiting for each renewal to fail:
# an India-issued card whose mandate is absent, inactive, or implied-USD (no stored non-USD
# fixing) cannot renew, because many Indian issuers refuse USD e-mandates. Pausing keeps
# access and sends the buyer onto the INR reauthorization path.
#
#   Onetime::PauseIndianCardMandateRenewals.process(seller_id: 123, dry_run: true)
#   Onetime::PauseIndianCardMandateRenewals.process(seller_id: 123)
class Onetime::PauseIndianCardMandateRenewals
  BATCH_SIZE = 100

  def self.process(seller_id:, dry_run: true)
    new(seller_id:, dry_run:).process
  end

  def initialize(seller_id:, dry_run: true)
    @seller_id = seller_id
    @dry_run = dry_run
  end

  def process
    scanned = 0
    paused = 0
    already_paused = 0
    mandate_check_errors = 0

    scope.find_in_batches(batch_size: BATCH_SIZE) do |subscriptions|
      ReplicaLagWatcher.watch unless dry_run

      subscriptions.each do |subscription|
        scanned += 1
        next unless subscription.india_card_mandate_reliability_enabled?
        # A membership that will never charge again (completed, or permanently free) needs no
        # mandate and must not be paused or emailed.
        next unless subscription.future_subscription_charge?

        card = subscription.credit_card_to_charge
        next unless card&.stripe_charge_processor? && card.requires_mandate?

        if subscription.renewal_disabled_due_to_indian_card_mandate? &&
           subscription.indian_card_mandate_requires_reauthorization?
          already_paused += 1
          next
        end

        observed_state = mandate_observed_state(subscription)
        begin
          next unless at_risk?(subscription, card)
        rescue ChargeProcessorError => e
          # A transient Stripe failure must not pause (and email) a member whose mandate may
          # be fine; skip and re-run for the leftovers. Only a real run reports these — dry-run
          # lookup noise is not actionable. (Anomaly reports from inside the lookup itself,
          # e.g. a mandate bound to another payment method, stay on for both: they flag bad
          # data worth seeing whenever it is observed.)
          mandate_check_errors += 1
          Rails.logger.info("[#{self.class.name}] mandate check failed for subscription #{subscription.external_id}: #{e.class}")
          ErrorNotifier.notify(e, subscription: subscription.external_id) unless dry_run
          next
        end

        if dry_run
          paused += 1
          next
        end

        subscription.with_lock do
          # A buyer can complete reauthorization between the classification above and this
          # lock; pausing then would undo their recovery and block the fresh mandate. Skip
          # when anything the classification read has changed — a re-run reclassifies.
          if mandate_observed_state(subscription) == observed_state
            # notify_buyer_if_already_disabled: a renewal-disabled membership without the
            # reauth flag was paused before the INR path deployed; this run's email is its
            # signal to come back and reauthorize.
            subscription.require_indian_card_mandate_reauthorization!(notify_buyer_if_already_disabled: true)
            paused += 1
          else
            Rails.logger.info("[#{self.class.name}] state changed mid-scan for subscription #{subscription.external_id}; skipped")
          end
        end
      end
    end

    Rails.logger.info(
      "[#{self.class.name}] seller_id=#{seller_id} scanned=#{scanned} " \
      "#{dry_run ? 'would_pause' : 'paused'}=#{paused} already_paused=#{already_paused} " \
      "mandate_check_errors=#{mandate_check_errors}"
    )
    { scanned:, paused:, already_paused:, mandate_check_errors: }
  end

  private
    attr_reader :seller_id, :dry_run

    def scope
      Subscription
        .where(seller_id:)
        .active_without_pending_cancel
        .not_is_installment_plan
        .joins(:link)
        .merge(Link.membership)
    end

    # At risk means the next off-session renewal cannot proceed: the membership has no
    # stored non-USD fixing (so its historical mandate, if any, was registered in USD), its
    # fixing cannot satisfy the non-USD currency the renewal will require, or the mandate
    # itself is gone or inactive.
    def at_risk?(subscription, card)
      presentment = subscription.current_later_charge_presentment
      return true if presentment.nil? || presentment.presentment_currency == Currency::USD

      terms_currency = subscription.indian_card_mandate_terms&.dig(:currency)
      # A stored non-USD fixing whose terms collapsed to canonical USD is incoherent: the
      # mandate on file was registered for the fixing's currency, and a USD renewal cannot
      # reference it.
      return true if terms_currency.blank? || terms_currency == Currency::USD
      return true if terms_currency != presentment.presentment_currency

      # A listed-currency fixing from a previous plan can sit beside a mandate approved
      # for that plan; the renewal would re-fix and submit against it. Compare the fixed
      # price, not the canonical value — FX re-fixing keeps the price and only moves the
      # canonical USD amount, while a plan change moves the price itself. Cross-currency
      # (quote-lane) fixings need no price check: terms only keep their currency while the
      # canonical value matches, and otherwise fall back to USD, which pauses above.
      purchase = subscription.original_purchase
      displayed_currency = (purchase&.displayed_price_currency_type.presence ||
        subscription.link.price_currency_type).to_s.downcase
      if displayed_currency == presentment.presentment_currency
        # Every price the current plan can legitimately fix: the signup price, this
        # cycle's discounted price, and the post-discount full price. A plan change
        # moves all of them away from the old fixing.
        plan_price_candidates = [
          purchase&.displayed_price_cents.to_i,
          subscription.current_subscription_price_cents.to_i,
          subscription.renewal_pre_discount_total_cents.to_i,
        ].select(&:positive?)
        return true if plan_price_candidates.any? &&
                       !plan_price_candidates.include?(presentment.presentment_price_cents)
      end

      _mandate, status, = subscription.indian_card_mandate_for(card.id)
      # "pending" is a transient registration state that CheckIndianCardMandateRegistrationJob
      # resolves on its own; pausing it here would flag a mandate that may activate moments
      # later. The cohort is inactive/missing only.
      !status.in?(%w[active pending])
    end

    def mandate_observed_state(subscription)
      [
        subscription.stripe_mandate_id,
        subscription.credit_card_to_charge&.id,
        subscription.renewal_disabled_due_to_indian_card_mandate?,
        subscription.indian_card_mandate_requires_reauthorization?,
        subscription.current_later_charge_presentment&.id,
      ]
    end
end
