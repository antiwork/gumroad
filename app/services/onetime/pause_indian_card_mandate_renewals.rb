# frozen_string_literal: true

# Pauses renewals for the memberships at risk of gp#1410: the saved card is India-issued and
# the recurring e-mandate Stripe holds is unusable for India recurring payments — it is
# absent, no longer active, or was registered in USD (any membership without a stored non-USD
# fixing charged in canonical USD, and many Indian issuers no longer accept USD e-mandates).
#
# The next off-session renewal for these memberships is guaranteed to fail, so pause them up
# front instead of waiting for each renewal date. `require_indian_card_mandate_reauthorization!`
# keeps the buyer's access, sends the existing "update your payment method" email once, and
# routes them through the INR reauthorization path.
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

        card = subscription.credit_card_to_charge
        next unless card&.stripe_charge_processor? && card.requires_mandate?

        if subscription.renewal_disabled_due_to_indian_card_mandate? &&
           subscription.indian_card_mandate_requires_reauthorization?
          already_paused += 1
          next
        end

        begin
          next unless at_risk?(subscription, card)
        rescue ChargeProcessorError => e
          # A transient Stripe failure must not pause (and email) a member whose mandate may
          # be fine; skip and re-run for the leftovers.
          mandate_check_errors += 1
          ErrorNotifier.notify(e, subscription: subscription.external_id)
          next
        end

        paused += 1
        subscription.require_indian_card_mandate_reauthorization! unless dry_run
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

    # At risk means the next off-session renewal cannot reference a usable INR e-mandate:
    # either the membership has no stored non-USD fixing (so its historical mandate, if any,
    # was registered in USD), or it has one but the mandate itself is gone or inactive.
    def at_risk?(subscription, card)
      presentment = subscription.current_later_charge_presentment
      return true if presentment.nil? || presentment.presentment_currency == Currency::USD

      _mandate, status, = subscription.indian_card_mandate_for(card.id)
      status != "active"
    end
end
