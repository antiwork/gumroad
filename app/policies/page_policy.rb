# frozen_string_literal: true

# Who can manage the seller's custom pages (design draft for
# gumroad-private#1047). Mirrors the profile-settings policy: marketing and
# admin roles can author pages, since pages are storefront content the same
# way the profile is.
class PagePolicy < ApplicationPolicy
  def index?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end

  def new?
    create?
  end

  def create?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def edit?
    index?
  end

  # The editor's preview pane renders custom HTML pages through the dashboard
  # (see PagesController#preview) — anyone who can open the editor can see it.
  def preview?
    edit?
  end

  def update?
    create?
  end

  def destroy?
    create?
  end
end
