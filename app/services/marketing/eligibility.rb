# frozen_string_literal: true

module Marketing::Eligibility
  # RedisFailOpen re-raises a read timeout for a gate it has not memoized; these
  # gates only gate marketing tools, so a stalled read means "not enabled".
  def self.enabled_for?(seller)
    return false unless seller.is_a?(User) && seller.persisted?

    assignment = Marketing::HoldoutAssignment.for_seller!(seller)
    !assignment.marketing_holdout? && flag_enabled?(seller)
  end

  def self.flag_enabled?(seller)
    Flipper.enabled?(:auto_marketing, seller)
  rescue ::Redis::BaseError, RedisClient::Error
    false
  end

  private_class_method :flag_enabled?
end
