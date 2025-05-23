# frozen_string_literal: true

class ProductReviewResponsePolicy < ApplicationPolicy
  def update?
    role_permitted? && owned_by_seller?
  end

  def destroy?
    role_permitted? && owned_by_seller?
  end

  private
    def role_permitted?
      user.role_owner_for?(seller) ||
        user.role_admin_for?(seller) ||
        user.role_support_for?(seller)
    end

    def owned_by_seller?
      when_record_available { record.product_review.link.user_id == seller.id }
    end
end
