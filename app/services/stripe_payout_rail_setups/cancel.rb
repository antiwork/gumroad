# frozen_string_literal: true

module StripePayoutRailSetups
  # Ends an open setup that cannot become active as prepared: compliance changed after preparation,
  # Stripe still needs information, or a card never linked. The seller can then submit a new
  # instrument, which prepares a fresh account from current details.
  #
  # Only this setup's own not-live account is retired, locally; the Stripe account, its id and any
  # recovery note stay as the record. The seller's current payout method is never touched.
  class Cancel
    FAILURE_CODE = "cancelled_by_staff"
    Result = Struct.new(:success, :error, keyword_init: true)

    def initialize(setup:, cancelled_by:, reason_reference:)
      @setup = setup
      @cancelled_by = cancelled_by
      @reason_reference = reason_reference
    end

    def process
      return Result.new(success: false, error: :not_authorized) unless cancelled_by&.is_team_member?
      return Result.new(success: false, error: :reference_missing) if reason_reference.blank?

      # One transaction, so a cancelled setup always carries its audit note.
      cancelled = setup.user.with_lock do
        next false unless setup.abandon!(FAILURE_CODE)

        setup.user.add_payout_note(
          content: "Payout rail setup ##{setup.id} cancelled by team member #{cancelled_by.email} (reference: #{reason_reference.strip}).",
          seller_visible: false
        )
        true
      end
      cancelled ? Result.new(success: true) : Result.new(success: false, error: :rail_setup_not_open)
    end

    private
      attr_reader :setup, :cancelled_by, :reason_reference
  end
end
