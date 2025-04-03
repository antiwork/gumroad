# frozen_string_literal: true

# Handles moving money around internally from Gumroad's Stripe
# account, into Stripe managed accounts. Transfers should be performed
# using the functions on this account rather than directly creating
# Stripe::Transfer objects, since transfers created here are logged to
# Slack rooms with the information needed to be able to track special
# case transfers.
module StripeTransferInternallyToCreator
  # Public: Creates a Stripe transfer that may or may not be attached to a charge.
  # Logs the transfer to the #payments chat room.
  # Returns the Stripe::Transfer object that was created.
  def self.transfer_funds_to_account(message_why:, stripe_account_id:, currency:, amount_cents:, related_charge_id: nil, metadata: nil)
    description = message_why
    description += " Related Charge ID: #{related_charge_id}." if related_charge_id

    transfer = Stripe::Transfer.create(
      destination: stripe_account_id,
      currency:,
      description:,
      amount: amount_cents,
      metadata:,
      expand: %w[balance_transaction])

    transfer
  end
end
