# frozen_string_literal: true

class FirstProductStarterPolicy < ApplicationPolicy
  def options?
    eligible?
  end

  def draft?
    eligible?
  end

  private
    def eligible?
      return false unless seller.eligible_for_first_product_starter?
      !seller.links.visible.exists?
    end
end
