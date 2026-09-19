# frozen_string_literal: true

module Marketing::Eligibility
  # RedisFailOpen answers a read timeout only for a gate it has already memoized;
  # for any other gate it re-raises the Redis error. These gates decide whether to
  # offer marketing tools, so a stalled read means "not enabled", never a 500.
  # The adapter already reports the error before re-raising it.
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
