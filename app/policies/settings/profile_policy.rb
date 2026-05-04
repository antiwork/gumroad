# frozen_string_literal: true

class Settings::ProfilePolicy < ApplicationPolicy
  def show?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end

  def update?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def update_username?
    user.role_owner_for?(seller)
  end

  def manage_social_connections?
    update_username?
  end

  def permitted_attributes
    user_attributes = [:name, :bio]
    user_attributes << :username if update_username?
    [
      :profile_picture_blob_id,
      {
        user: user_attributes,
        seller_profile: [:highlight_color, :background_color, :font],
        tabs: [:name, { sections: [] }]
      }
    ]
  end
end
