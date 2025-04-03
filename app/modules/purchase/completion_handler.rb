# frozen_string_literal: true

module Purchase::CompletionHandler
  # Makes sure that a block of code that creates an in_progress purchase eventually transitions
  # that purchase to a completing state, otherwise this method marks the purchase as failed.
  def ensure_completion
    yield
  ensure
    mark_failed! if persisted? && in_progress? && (!charge_intent&.is_a?(StripeChargeIntent) || !(charge_intent&.processing? || charge_intent&.requires_action?))
  end
end
