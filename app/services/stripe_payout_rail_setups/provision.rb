# frozen_string_literal: true

module StripePayoutRailSetups
  # Creates (or recovers) the managed Stripe account for a pending setup and links a bank candidate,
  # without making either live. Account creation keeps its own idempotency key and unknown-outcome
  # recovery, so retries replay or adopt the first account instead of opening a second one; nothing
  # here wraps the provider call in a transaction.
  class Provision
    ATTEMPT_LEASE = 10.minutes
    FOREIGN_BLOCKER_FAILURE_CODE = StripePayoutRailSetup::FOREIGN_BLOCKER_FAILURE_CODE
    Result = Struct.new(:success, :error, :exception, keyword_init: true)

    def self.attempt_in_progress?(setup)
      setup.attempt_started_at.present? && setup.attempt_started_at > ATTEMPT_LEASE.ago
    end

    def initialize(setup)
      @setup = setup
    end

    def process
      # Checked before the claim, so a seller who left the rollout keeps the setup and its recovery
      # facts exactly as they are, with no new provider work.
      return Result.new(success: false, error: :not_eligible) unless setup.provider_work_allowed?

      token = StripePayoutRailSetup.claim_attempt!(setup.id, lease: ATTEMPT_LEASE)
      return Result.new(success: false, error: :rail_setup_not_pending) if token.nil?

      setup.reload
      # notify: false — the ordinary rejection notes would put the seller in the weekly retry, which
      # creates live accounts; a refused setup records its failure_code instead.
      merchant_account = adoptable_account || StripeMerchantAccountManager.create_account(
        setup.user,
        passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"),
        notify: false,
        rail_setup: setup
      )
      state = setup.card? ? StripePayoutRailSetup::AWAITING_CARD_LINK : StripePayoutRailSetup::PREPARED
      unless setup.finish_attempt!(token, state:, merchant_account_id: merchant_account.id, prepared_at: Time.current)
        # A newer attempt that reclaimed the lease can adopt this account; a setup abandoned while
        # Stripe was answering cannot, so its account is retired instead.
        setup.retire_prepared_account!(merchant_account)
        return Result.new(success: false, error: :stale_attempt)
      end

      if setup.awaiting_card_link?
        link = LinkStagedCard.new(setup)
        link_result = link.process
        LinkStagedRailCardJob.perform_async(setup.id) if LinkStagedCard::RETRY_RESULTS.include?(link_result)
        return Result.new(success: false, error: :provider_error, exception: link.error) if link_result == :failed
      end
      Result.new(success: true)
    rescue Stripe::StripeError, MerchantRegistrationUserNotReadyError, MerchantRegistrationUserAlreadyHasAccountError => e
      # An older not-live account with a Stripe id is not another attempt of this setup: nothing will
      # clear it, so the setup ends rather than waiting. The account itself is left for support.
      if e.instance_of?(MerchantRegistrationUserAlreadyHasAccountError) && (blocker = setup.foreign_blocking_account)
        return fail_for_foreign_blocker(token, blocker, e)
      end

      # Stays pending when the outcome is unknown (Stripe may have created the account) or another
      # attempt's account is still being set up; only a known refusal fails the setup.
      if known_refusal?(e)
        setup.abandon_recovery_notes! if setup.finish_attempt!(token, state: StripePayoutRailSetup::FAILED, failure_code: failure_code_for(e), failed_at: Time.current)
      else
        setup.finish_attempt!(token)
      end
      Result.new(success: false, error: :provider_error, exception: e)
    rescue StandardError
      setup.finish_attempt!(token)
      raise
    end

    private
      attr_reader :setup

      def known_refusal?(error)
        return false if error.is_a?(MerchantRegistrationUserAlreadyHasAccountError)

        !StripeMerchantAccountManager.no_verdict_stripe_error?(error)
      end

      # An earlier attempt whose lease was reclaimed may have finished creating this setup's account
      # after all. Reuse it rather than opening a second one: it is the user's only unlive managed row
      # tagged with this setup, create_account marked it complete, and a bank candidate is linked to it.
      # A row without the mark may still be deleted by the attempt creating it, so the setup waits.
      def adoptable_account
        candidates = setup.user.merchant_accounts.alive.stripe
          .where(charge_processor_alive_at: nil)
          .where.not(charge_processor_merchant_id: nil)
          .where(created_at: setup.created_at..)
          .select { |account| account.rail_setup_id == setup.id.to_s && !account.is_a_stripe_connect_account? }
        return nil unless candidates.one?

        account = candidates.first
        return nil unless account.rail_setup_completed_id == setup.id.to_s
        return account if setup.card?

        account if setup.bank_account.stripe_connect_account_id == account.charge_processor_merchant_id && setup.bank_account.stripe_bank_account_id.present?
      end

      def fail_for_foreign_blocker(token, blocker, error)
        failed = setup.finish_attempt!(token, state: StripePayoutRailSetup::FAILED, failure_code: FOREIGN_BLOCKER_FAILURE_CODE, failed_at: Time.current)
        if failed
          setup.abandon_recovery_notes!
          setup.user.add_payout_note(
            content: "Payout rail setup ##{setup.id} stopped: managed account ##{blocker.id} predates it and blocks a new one; it needs a support repair.",
            seller_visible: false
          )
        end
        Result.new(success: false, error: :existing_managed_account, exception: error)
      end

      def failure_code_for(error)
        (error.try(:code).presence || error.class.name.demodulize.underscore).to_s
      end
  end
end
