# frozen_string_literal: true

class Admin::Impersonators::UserPolicy < ApplicationPolicy
  def create?
    return false if record.is_team_member? || record.deleted?

    true
  end
end
