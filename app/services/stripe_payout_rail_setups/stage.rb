# frozen_string_literal: true

module StripePayoutRailSetups
  # Saves a new bank account or debit card as the candidate of a rail setup, leaving the seller's
  # current payout method, bank row, PayPal address and payout schedule exactly as they are.
  class Stage
    Result = Struct.new(:success, :error, :data, :field, :setup, keyword_init: true)

    PAYOUT_PREFERENCE_PARAMS = %i[payout_threshold_cents payout_frequency payouts_paused_by_user].freeze

    # Exactly one new instrument and no PayPal address: a combined request would be ambiguous.
    def self.applies_to?(seller, params)
      params.dig(:bank_account, :account_number).present? != params[:card].present? &&
        params[:payment_address].blank? &&
        seller.stripe_account.blank? &&
        seller.stripe_connect_account.present? &&
        !seller.has_stripe_account_connected? &&
        seller.payout_rail_beside_inactive_connect_enabled?
    end

    # Preparation must not move card routing or the payout schedule. A change to the countries or
    # account type that decide Connect routing, or to a payout preference, has to be saved on its own.
    def self.conflicting_change(seller, params)
      user_params = params[:user] || {}
      compliance_info = seller.alive_user_compliance_info
      return :routing_details_changed if compliance_info.nil?

      # Predicts what UpdateUserComplianceInfo#assign_compliance_params persists. It casts is_business,
      # but writes country and business_country whenever the raw param is truthy in Ruby, so a form
      # "off" or "false" still writes them, and an unknown code clears them. A JSON false does not.
      raw_is_business = user_params[:is_business]
      is_business = raw_is_business.nil? ? compliance_info.is_business? : ActiveModel::Type::Boolean.new.cast(raw_is_business)
      return :routing_details_changed if !!is_business != !!compliance_info.is_business?

      %i[country business_country].each do |field|
        next unless raw_is_business && user_params[field].present?
        return :routing_details_changed if Compliance::Countries.mapping[user_params[field]] != compliance_info.public_send(field)
      end

      changed_preference = PAYOUT_PREFERENCE_PARAMS.any? do |name|
        next false if params[name].nil?

        current = seller.public_send(name)
        submitted = current.is_a?(Integer) ? params[name].to_i : params[name]
        submitted = ActiveModel::Type::Boolean.new.cast(submitted) if [true, false].include?(current)
        # The settings page raises an untouched threshold below the current minimum to that minimum
        # before saving, so that value is the stored one, not a change.
        next false if name == :payout_threshold_cents && submitted == [current.to_i, seller.minimum_payout_threshold_cents].max
        submitted.to_s != current.to_s
      end
      changed_preference ? :payout_preferences_changed : nil
    end

    def initialize(seller:, params:)
      @seller = seller
      @params = params
    end

    def process
      payout_method = UpdatePayoutMethod.new(user_params: params, seller:)
      candidate, error = params[:card].present? ? payout_method.prepare_card_candidate : payout_method.prepare_bank_account_candidate
      return Result.new(success: false, **error) if error

      result = seller.with_lock do
        setup = StripePayoutRailSetup.open_for(seller)
        if setup.nil?
          save_candidate!(candidate)
          next Result.new(success: true, setup: seller.stripe_payout_rail_setups.create!(bank_account: candidate))
        end
        next Result.new(success: false, error: :rail_setup_in_progress) unless setup.pending? && !Provision.attempt_in_progress?(setup)
        next Result.new(success: true, setup:) if same_instrument?(setup.bank_account, candidate)
        # Once Stripe has been asked, the candidate is bound to that attempt's recovery context and a
        # retry may only resume it. Before that, the newer request simply replaces the candidate.
        next Result.new(success: false, error: :rail_setup_other_instrument) unless replace_unattempted_candidate!(setup, candidate)

        Result.new(success: true, setup: setup.reload)
      end
      payout_method.discard_card_candidate!(candidate) if candidate.is_a?(CardBankAccount) && candidate.new_record?
      result
    end

    private
      attr_reader :seller, :params

      # Conditional on attempt_count, since a Provision claim does not take the seller lock: one that
      # slipped in first keeps its candidate, and the savepoint drops the one saved here.
      def replace_unattempted_candidate!(setup, candidate)
        return false unless setup.attempt_count.zero?

        replaced = false
        StripePayoutRailSetup.transaction(requires_new: true) do
          save_candidate!(candidate)
          replaced = StripePayoutRailSetup.where(id: setup.id, state: StripePayoutRailSetup::PENDING, attempt_count: 0)
            .update_all(bank_account_id: candidate.id, updated_at: Time.current) == 1
          raise ActiveRecord::Rollback unless replaced
        end
        replaced
      end

      def save_candidate!(candidate)
        candidate.staged_rail_candidate = true
        candidate.deleted_at = Time.current
        candidate.save!
      end

      def same_instrument?(staged, submitted)
        return false unless staged.instance_of?(submitted.class)
        return staged.credit_card&.stripe_fingerprint.present? && staged.credit_card.stripe_fingerprint == submitted.credit_card&.stripe_fingerprint if staged.is_a?(CardBankAccount)

        passphrase = GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")
        staged.routing_number == submitted.routing_number &&
          staged.account_number.decrypt(passphrase) == submitted.account_number.decrypt(passphrase) &&
          staged.account_holder_full_name == submitted.account_holder_full_name &&
          staged.account_type == submitted.account_type
      end
  end
end
