# frozen_string_literal: true

# Products > Edit product
class DropboxFilesPolicy < ApplicationPolicy
  def create?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def index?
    create?
  end

  def cancel_upload?
    create?
  end
end
