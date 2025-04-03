# frozen_string_literal: true

class Integrations::BaseIntegrationService
  include ActiveModel::Validations
  attr_accessor :integration_name
  validates :integration_name, presence: true

  def initialize
    raise "#{self.class.name} should not be instantiated. Instantiate child classes instead."
  end

  def activate(purchase)
    integration = purchase.find_enabled_integration(integration_name)
    return unless integration

    yield integration if block_given?
  end

  def deactivate(purchase)
    integration = purchase.find_enabled_integration(integration_name)
    return if integration.blank? || integration.keep_inactive_members?

    yield integration if block_given?
  end

  # For now since all tiers have the same integration, the logic is simple.
  # In case we allow different integrations for different tiers we will have a
  # lot of edge cases to check when we update a tier.
  def update_on_tier_change(subscription)
    previous_purchase = subscription.purchases.is_original_subscription_purchase.order(:id)[-2]
    return unless previous_purchase.present?

    old_integration = previous_purchase.find_enabled_integration(integration_name)
    new_integration = subscription.original_purchase.find_enabled_integration(integration_name)

    activate(subscription.original_purchase) if new_integration.present? && old_integration.blank?
    deactivate(previous_purchase) if new_integration.blank? && old_integration.present?
  end
end
