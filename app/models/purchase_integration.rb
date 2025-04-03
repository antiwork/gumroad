# frozen_string_literal: true

class PurchaseIntegration < ApplicationRecord
  include Deletable

  belongs_to :purchase, optional: true
  belongs_to :integration, optional: true

  validates :purchase_id, presence: true
  validates :integration_id, presence: true
  validates :integration_id, uniqueness: { scope: %i[purchase_id deleted_at] }, unless: :deleted?
  validates :discord_user_id, presence: true, if: -> { integration&.type === DiscordIntegration.name }
  validate :matches_integration_on_product
  validate :unique_for_integration_type

  def unique_for_integration_type
    return if purchase.nil? || integration.nil?
    return unless purchase.active_integrations.where(type: integration.type).where.not(id: integration.id).exists?

    errors.add(:base, "Purchase cannot have multiple integrations of the same type.")
  end

  def matches_integration_on_product
    return if purchase.nil? || integration.nil?
    return if purchase.find_enabled_integration(integration.name) === integration

    errors.add(:base, "Integration does not match the one available for the associated product.")
  end
end
