# frozen_string_literal: true

# Mixed into the things that control a charge happening after the buyer leaves checkout —
# Subscription (memberships and installment plans), Preorder, and Commission. Gives each of them
# the same two readers over its fixed buyer-currency amounts, so the charge paths do not each
# grow their own way of asking the question.
#
# Why the amount is fixed rather than re-quoted per charge, and why rows are immutable and
# effective-dated, is explained on LaterChargePresentment.
module HasLaterChargePresentments
  extend ActiveSupport::Concern

  included do
    # Present only when the buyer is billed in their own currency; absent for the USD-billed
    # majority. One row per fixing rather than one per owner.
    has_many :later_charge_presentments, as: :owner, dependent: :destroy
  end

  # The fixing a later charge should read: the most recent one that has taken effect. nil means
  # this owner has no buyer-currency amount and its later charges bill canonical US dollars,
  # which is the case for every owner today.
  def current_later_charge_presentment
    LaterChargePresentment.current_for(self)
  end

  # The buyer-currency amount to bill on a later charge, or nil when there is none and the charge
  # should fall back to canonical US dollars. Deliberately does NOT consult a current exchange
  # rate: the stored amount is what the buyer agreed to and is authoritative.
  def fixed_later_charge_price_cents
    current_later_charge_presentment&.presentment_price_cents
  end

  # The currency a later charge should present in, or nil when it should bill canonical dollars.
  def later_charge_presentment_currency
    current_later_charge_presentment&.presentment_currency
  end
end
