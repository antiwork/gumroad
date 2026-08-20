# frozen_string_literal: true

class SellerRefundPolicy < RefundPolicy
  validates :seller, presence: true, uniqueness: { conditions: -> { where(product_id: nil) } }
  validate :refund_period_meets_enforcement_minimum, if: :seller_has_enforced_refund_policy?

  private
    # When a seller's dispute rate got too high, the platform enforces a buyer-friendly
    # refund policy on their account (see
    # Purchase::Blockable#enforce_refund_policy_for_seller_based_on_dispute_rate!).
    # While that enforcement is active, the seller cannot switch back to
    # "No refunds allowed" (0 days) — any refund window of at least 7 days is fine.
    # This lives in the model so both the settings UI and the public API are covered.
    def refund_period_meets_enforcement_minimum
      return if max_refund_period_in_days.present? && max_refund_period_in_days >= 7

      errors.add(:max_refund_period_in_days, "must offer a refund period of at least 7 days while a refund policy is enforced on this account")
    end

    def seller_has_enforced_refund_policy?
      # Check the flag on a fresh read rather than the cached `seller` association:
      # when the enforcement flips the flag and updates the policy in the same request,
      # the association target can be a stale instance loaded before the flag was set.
      seller_id.present? && User.where(id: seller_id).where("flags & ? != 0", User.flag_mapping["flags"][:refund_policy_enforced]).exists?
    end
end
