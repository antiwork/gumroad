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
    # custom_html is intentionally clear-only from this surface: the editor never edits the HTML
    # (the agent + `gumroad user page` CLI author it via the v2 API), it only sends "" to reset.
    # The User#custom_html= setter treats blank as "remove the page".
    user_attributes = [:name, :bio, :custom_html]
    [
      :profile_picture_blob_id,
      :profile_version,
      {
        user: user_attributes,
        tabs: [:name, { sections: [] }],
        sections: [:id, *ProfileSectionPolicy::CREATE_ATTRIBUTES]
      }
    ]
  end
end
