# frozen_string_literal: true

class ProductReviewVideoPolicy < ApplicationPolicy
  def approve?
    role_permitted? && owned_by_seller?(record)
  end

  def reject?
    approve?
  end

  private
    def role_permitted?
      user.role_owner_for?(seller) ||
        user.role_admin_for?(seller) ||
        user.role_support_for?(seller)
    end

    def owned_by_seller?(record)
      record.product_review.purchase.seller_id == seller.id
    end
end
