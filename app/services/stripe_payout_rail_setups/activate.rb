# frozen_string_literal: true

module StripePayoutRailSetups
  # The only path that switches a prepared rail on. It changes the seller's payout destination
  # (and card sales then go through the managed account), so the caller must be a team member
  # acting on the seller's recorded consent; the consent itself is attested here, not verified.
  class Activate
    # details names what is missing on a provider or compliance refusal, so staff can act on it.
    Result = Struct.new(:success, :error, :details, keyword_init: true)
    USABLE_BANK_STATUSES = %w[new validated verified].freeze

    def initialize(setup:, activated_by:, consent_reference:)
      @setup = setup
      @activated_by = activated_by
      @consent_reference = consent_reference
    end

    def process
      error = precondition_error
      return Result.new(success: false, error:) if error

      checked = snapshot
      stripe_account = Stripe::Account.retrieve(setup.merchant_account.charge_processor_merchant_id)
      return Result.new(success: false, error: :stripe_account_not_ready, details: readiness_details(stripe_account)) unless account_ready?(stripe_account)
      return Result.new(success: false, error: :payout_destination_not_usable) unless destination_usable?(stripe_account)

      result = nil
      user.with_lock do
        setup.reload
        error = precondition_error
        error ||= :rail_setup_changed if snapshot != checked
        unless error || compliance_synced?(stripe_account)
          next result = Result.new(success: false, error: :compliance_changed_since_preparation, details: {
                                     synced_compliance_revision: synced_compliance_revision(stripe_account),
                                     current_compliance_revision: user.alive_user_compliance_info&.external_id,
                                   })
        end
        error ||= :guardian_changed_since_preparation unless guardian_synced?
        next result = Result.new(success: false, error:) if error

        bank_account = setup.bank_account
        user.bank_accounts.alive.where.not(id: bank_account.id).find_each do |old_bank_account|
          old_bank_account.deleted_at = Time.current
          old_bank_account.save!(validate: false)
        end
        bank_account.deleted_at = nil
        bank_account.save!(validate: false)

        setup.merchant_account.update!(charge_processor_alive_at: Time.current)
        user.update!(payment_address: "", invalidated_paypal_payout_address: nil) if user.payment_address.present? || user.invalidated_paypal_payout_address.present?
        setup.update!(state: StripePayoutRailSetup::ACTIVATED, activated_at: Time.current, activated_by:, consent_reference:)
        result = Result.new(success: true)
      end
      if result.success
        UserComplianceInfoRequest.handle_new_bank_account(setup.bank_account)
        # The check queued while preparing ran with the candidate still deleted, and the worker only
        # reads alive bank rows, so it never saw this destination. Same check as an ordinary link.
        CheckPaymentAddressWorker.perform_async(user.id)
      end
      result
    end

    private
      attr_reader :setup, :activated_by, :consent_reference

      def user
        setup.user
      end

      def precondition_error
        return :rollout_gate_closed unless user.payout_rail_beside_inactive_connect_enabled?
        return :not_authorized unless activated_by&.is_team_member?
        return :consent_missing if consent_reference.blank?
        return :rail_setup_not_prepared unless setup.prepared?
        return :account_inactive unless user.account_active?

        merchant_account = setup.merchant_account
        bank_account = setup.bank_account
        if merchant_account.nil? || merchant_account.user_id != user.id || merchant_account.is_a_stripe_connect_account? ||
           !merchant_account.alive? || merchant_account.charge_processor_alive? || merchant_account.charge_processor_merchant_id.blank?
          return :rail_not_prepared
        end
        if bank_account.user_id != user.id || bank_account.alive? || bank_account.stripe_bank_account_id.blank? ||
           bank_account.stripe_connect_account_id != merchant_account.charge_processor_merchant_id
          return :bank_link_not_ready
        end
        return :incompatible_bank_rail if merchant_account.country != user.alive_user_compliance_info&.legal_entity_country_code
        return :connect_route_active if user.has_stripe_account_connected?
        return :connect_removed if user.stripe_connect_account.blank?
        return :managed_account_exists if user.stripe_account.present?
        :payout_in_flight if user.payments.where(state: UpdateUserCountry::PAYOUT_IN_FLIGHT_STATES).exists?
      end

      # Everything the provider read must not race: a seller who saves a new PayPal address, payout
      # preference, bank or compliance revision meanwhile must not have it overwritten from a stale view.
      # Compliance saves always insert a new row, so the alive row's id and timestamps identify a revision.
      def snapshot
        payout_user = User.find(user.id)
        [
          setup.attributes, setup.merchant_account&.attributes, setup.bank_account&.attributes,
          payout_user.attributes.slice("payment_address", "invalidated_paypal_payout_address", "flags", "json_data"),
          payout_user.bank_accounts.alive.pluck(:id),
          payout_user.alive_user_compliance_info&.attributes&.slice("id", "updated_at"),
          StripePayoutRailSetup.guardian_fingerprint(payout_user),
        ]
      end

      # Retrievable is not payable: a deleted or restricted account is still returned.
      def account_ready?(stripe_account)
        return false if stripe_account["deleted"]
        return false if stripe_account["requirements"]&.[]("disabled_reason").present?
        return false unless stripe_account["payouts_enabled"] == true

        stripe_account["country"].blank? || stripe_account["country"] == setup.merchant_account.country
      end

      # Compliance saves are not synced to an account that is not live yet. Stripe's metadata names the
      # revision the account last received (update_account reads it the same way); checked under the lock.
      def compliance_synced?(stripe_account)
        synced_id = synced_compliance_revision(stripe_account)
        synced_id.present? && synced_id == user.alive_user_compliance_info&.external_id
      end

      # Nothing syncs a guardian to an account that is not live, so it must be the one the
      # provisioning sync sent. No guardian involved now means nothing to compare.
      def guardian_synced?
        current = StripePayoutRailSetup.guardian_fingerprint(user)
        current.nil? || setup.merchant_account.rail_guardian_fingerprint == current
      end

      def synced_compliance_revision(stripe_account)
        stripe_account["metadata"]&.[]("user_compliance_info_id")
      end

      def readiness_details(stripe_account)
        requirements = stripe_account["requirements"]
        {
          payouts_enabled: stripe_account["payouts_enabled"],
          disabled_reason: requirements&.[]("disabled_reason"),
          currently_due: Array(requirements&.[]("currently_due")),
          past_due: Array(requirements&.[]("past_due")),
        }
      end

      # Presence is not usability: the external account this setup created must still be attached and
      # payable. Bank accounts report status (Stripe stops paying out to verification_failed or errored
      # ones); a debit card must offer standard payouts.
      def destination_usable?(stripe_account)
        external_accounts = stripe_account["external_accounts"]&.[]("data")
        candidate = setup.bank_account
        external_account = Array(external_accounts).find { |account| account["id"] == candidate.stripe_bank_account_id }
        return false if external_account.nil? || external_account["deleted"]
        # What provisioning sent Stripe, which for a cross-border SEPA IBAN is the IBAN's country and EUR.
        return false unless external_account["currency"].to_s.casecmp?(candidate.stripe_external_account_currency) &&
                            external_account["country"].to_s == candidate.stripe_external_account_country

        if candidate.is_a?(CardBankAccount)
          external_account["object"] == "card" && Array(external_account["available_payout_methods"]).include?("standard")
        else
          external_account["object"] == "bank_account" && USABLE_BANK_STATUSES.include?(external_account["status"])
        end
      end
  end
end
