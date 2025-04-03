# frozen_string_literal: true

class PreorderLink < ApplicationRecord
  REMINDER_EMAIL_TO_RELEASE_TIME = 1.day # Send the seller reminder email 1 day before the release time.

  belongs_to :link, optional: true
  has_many :preorders

  validates :link, presence: true
  validates :release_at, presence: true
  validate :release_at_validation, if: ->(preorder_link) { preorder_link.changes["release_at"].present? }

  attr_accessor :is_being_manually_released_by_the_seller

  state_machine(:state, initial: :unreleased) do
    before_transition unreleased: :released, do: :eligible_for_release?

    after_transition unreleased: :released, do: :mark_link_as_released
    after_transition unreleased: :released, do: :charge_successful_preorders

    event :mark_released do
      transition unreleased: :released
    end
  end

  def build_preorder(authorization_purchase)
    preorders.build(seller: link.user,
                    purchaser: authorization_purchase.purchaser,
                    purchases: [authorization_purchase])
  end

  def revenue_cents
    link.sales.successful.where("preorder_id is not null").sum(:price_cents)
  end

  def release!
    # Lock the object to guarantee that no two jobs will try to release the product at the same time.
    # There are other safeguards against that, but locking here as well in order to increase confidence.
    released_successfully = false
    with_lock do
      released_successfully = mark_released
    end

    released_successfully
  end

  private
    def eligible_for_release?
      return false if link.banned_at.present? || link.deleted_at.present?
      return false if !link.alive? && !is_being_manually_released_by_the_seller
      return false if !link.is_physical? && !link.has_content?

      unless is_being_manually_released_by_the_seller
        # Enforce that the pre-order's release time should be in the past, unless the seller is manually releasing the product.
        return false if !link.is_in_preorder_state? || release_at > 1.minute.from_now # Account for slight time differences between instances
      end

      true
    end

    def mark_link_as_released
      link.update(is_in_preorder_state: false)
      # past this point no new preorders will be created for this product
    end

    def charge_successful_preorders
      ChargeSuccessfulPreordersWorker.perform_in(5.seconds, id)
    end

    def release_at_validation
      errors.add :base, "The release time of your pre-order has to be at least 24 hours from now." if release_at <= 24.hours.from_now
    end
end
