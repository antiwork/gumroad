# frozen_string_literal: true

class Integrations::CircleIntegrationService < Integrations::BaseIntegrationService
  def initialize
    @integration_name = Integration::CIRCLE
  end

  def activate(purchase)
    super { |integration| CircleApi.new(integration.api_key).add_member(integration.community_id, integration.space_group_id, purchase.email) }
  end

  def deactivate(purchase)
    super { |integration| CircleApi.new(integration.api_key).remove_member(integration.community_id, purchase.email) }
  end
end
