# frozen_string_literal: true

class Collaborator < Affiliate
  MIN_PERCENT_COMMISSION = 1
  MAX_PERCENT_COMMISSION = 50

  belongs_to :seller, class_name: "User"

  has_one :collaborator_invitation, dependent: :destroy

  validates :seller_id, uniqueness: { scope: [:affiliate_user_id, :deleted_at] }, unless: :deleted?
  validates :affiliate_basis_points, presence: true, if: -> { apply_to_all_products? }
  validates :affiliate_basis_points, numericality: { greater_than_or_equal_to: MIN_PERCENT_COMMISSION * 100,
                                                     less_than_or_equal_to: MAX_PERCENT_COMMISSION * 100,
                                                     allow_nil: true }
  validate :collaborator_does_not_require_approval, if: :affiliate_user_changed?
  validate :eligible_for_stripe_payments

  scope :invitation_accepted, -> { where.missing(:collaborator_invitation) }
  scope :invitation_pending, -> { joins(:collaborator_invitation) }

  def as_json(*)
    {
      id: external_id,
      email: affiliate_user.email,
      name: affiliate_user.display_name(prefer_email_over_default_username: true),
      avatar_url: affiliate_user.avatar_url,
      apply_to_all_products:,
      percent_commission: affiliate_percentage,
      setup_incomplete: !affiliate_user.has_valid_payout_info?,
      dont_show_as_co_creator:,
      invitation_accepted: invitation_accepted?,
    }
  end

  def invitation_accepted?
    collaborator_invitation.blank?
  end

  def mark_deleted!
    super
    products.each { _1.update!(is_collab: false) }
  end

  def basis_points(product_id: nil)
    return affiliate_basis_points if product_id.blank?

    product_affiliates.find_by(link_id: product_id)&.affiliate_basis_points || affiliate_basis_points
  end

  def show_as_co_creator_for_product?(product)
    apply_to_all_products? ? !dont_show_as_co_creator? : !product_affiliates.find_by(link_id: product.id).dont_show_as_co_creator?
  end

  private
    def collaborator_does_not_require_approval
      if affiliate_user&.require_collab_request_approval?
        errors.add(:base, "You cannot add this user as a collaborator")
      end
    end

    def eligible_for_stripe_payments
      super
      return unless seller.present? && seller.has_brazilian_stripe_connect_account?
      errors.add(:base, "You cannot add a collaborator because you are using a Brazilian Stripe account.")
    end
end
