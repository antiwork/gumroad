# frozen_string_literal: true

module Marketing::Eligibility
  def self.enabled_for?(seller)
    return false unless seller.is_a?(User) && seller.persisted?

    assignment = Marketing::HoldoutAssignment.for_seller!(seller)
    !assignment.marketing_holdout? && Flipper.enabled?(:auto_marketing, seller)
  end
end
