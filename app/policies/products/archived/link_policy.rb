# frozen_string_literal: true

class Products::Archived::LinkPolicy < ApplicationPolicy
  def index?
    Pundit.policy!(@context, Link).index?
  end

  def create?
    Pundit.policy!(@context, Link).new? &&
    record.not_archived?
  end

  def destroy?
    Pundit.policy!(@context, Link).new? &&
    record.archived?
  end
end
