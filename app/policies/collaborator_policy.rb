# frozen_string_literal: true

class CollaboratorPolicy < ApplicationPolicy
  def index?
    user.role_admin_for?(seller)
  end

  def create?
    index?
  end

  def new?
    index?
  end

  def edit?
    index? && when_record_available { record.seller == seller }
  end

  def update?
    edit?
  end

  def destroy?
    return false unless user.role_admin_for?(seller)
    when_record_available { record.seller == seller || record.affiliate_user == seller }
  end
end
