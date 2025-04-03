# frozen_string_literal: false

# Handles moving money around internally from Gumroad's Stripe
# account, into Stripe managed accounts. Transfers should be performed
# using the functions on this account rather than directly creating
# Stripe::Transfer objects, since transfers created here are logged to
# Slack rooms with the information needed to be able to track special
# case transfers.
module StripeTransferAffiliateCredits
  # Public: Creates a Stripe transfer that may or may not be attached to a charge.
  # Returns the Stripe::Transfer object that was created.
  def self.transfer_funds_to_account(description:, stripe_account_id:, amount_cents:, transfer_group:, related_charge_id: nil, metadata: nil)
    amount_cents_formatted = Money.new(amount_cents, "usd").format(no_cents_if_whole: false, symbol: true)
    message = <<-EOS
      Creating Affiliate transfer for #{description}.
      Related Charge ID: <#{StripeUrl.charge_url(related_charge_id)}|#{related_charge_id}>
      Amount: #{amount_cents_formatted}
    EOS
    message.strip!

    Rails.logger.info(message)

    transfer = Stripe::Transfer.create(
      destination: stripe_account_id,
      currency: "usd",
      amount: amount_cents,
      description:,
      metadata:,
      transfer_group:,
      expand: %w[balance_transaction application_fee.balance_transaction]
    )

    transfer
  end
end
