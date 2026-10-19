# frozen_string_literal: true

module StripePayoutRailSetups
  # Stripe only accepts a debit card as an external account once the account has charges enabled,
  # so a card setup waits in AWAITING_CARD_LINK until then. This attaches the card to the setup's own
  # prepared account and marks the setup prepared; it never makes the card or the account live.
  class LinkStagedCard
    # Outcomes that leave the setup waiting with nothing else due to pick it up again.
    RETRY_RESULTS = %i[retry_later attempt_in_progress].freeze

    def self.enqueue_if_ready(stripe_account)
      return unless stripe_account["charges_enabled"]

      setup = StripePayoutRailSetup.joins(:merchant_account)
        .where(state: StripePayoutRailSetup::AWAITING_CARD_LINK, merchant_accounts: { charge_processor_merchant_id: stripe_account["id"] })
        .first
      LinkStagedRailCardJob.perform_async(setup.id) if setup
    end

    def initialize(setup)
      @setup = setup
    end

    # The Stripe refusal behind a :failed result.
    attr_reader :error

    # Returns :linked, :awaiting_charges, :not_awaiting, :not_eligible, :failed, :retry_later or
    # :attempt_in_progress.
    # A retry repeats the whole link with the same idempotency keys, so within Stripe's 24 hours it
    # replays the first token and update; after that a new token replaces the account's external
    # account, as the ordinary card linker relies on, so it never adds a second card.
    def process
      return :not_eligible unless setup.provider_work_allowed?

      token = StripePayoutRailSetup.claim_attempt!(setup.id, lease: Provision::ATTEMPT_LEASE, state: StripePayoutRailSetup::AWAITING_CARD_LINK)
      return setup.reload.awaiting_card_link? ? :attempt_in_progress : :not_awaiting if token.nil?

      setup.reload
      merchant_account = setup.merchant_account
      unless merchant_account&.alive? && !merchant_account.charge_processor_alive?
        setup.finish_attempt!(token, from_state: StripePayoutRailSetup::AWAITING_CARD_LINK)
        return :not_awaiting
      end

      stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
      unless stripe_account["charges_enabled"]
        setup.finish_attempt!(token, from_state: StripePayoutRailSetup::AWAITING_CARD_LINK)
        return :awaiting_charges
      end

      # The Stripe write holds the seller lock that Activate, Cancel and abandonment take, and the setup row
      # a newer attempt must update to reclaim the lease, so a worker that lost the attempt writes nothing.
      linked = setup.user.with_lock do
        current = StripePayoutRailSetup.lock.find(setup.id)
        next false unless current.awaiting_card_link? && current.attempt_token == token

        StripeMerchantAccountManager.link_staged_rail_card!(setup.bank_account, stripe_account, rail_setup: setup, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        setup.finish_attempt!(token, from_state: StripePayoutRailSetup::AWAITING_CARD_LINK, state: StripePayoutRailSetup::PREPARED, prepared_at: Time.current)
      end
      linked ? :linked : :not_awaiting
    rescue Stripe::StripeError => e
      if StripeMerchantAccountManager.no_verdict_stripe_error?(e)
        setup.finish_attempt!(token, from_state: StripePayoutRailSetup::AWAITING_CARD_LINK)
        :retry_later
      else
        setup.finish_attempt!(token, from_state: StripePayoutRailSetup::AWAITING_CARD_LINK, state: StripePayoutRailSetup::FAILED,
                                     failure_code: (e.try(:code).presence || e.class.name.demodulize.underscore).to_s, failed_at: Time.current)
        setup.retire_prepared_account!
        @error = e
        :failed
      end
    end

    private
      attr_reader :setup
  end
end
