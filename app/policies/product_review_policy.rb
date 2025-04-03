# frozen_string_literal: true

class ProductReviewPolicy < ApplicationPolicy
  def index?
    user.role_owner_for?(seller) && Feature.active?(:reviews_page, user)
  end
end
