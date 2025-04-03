# frozen_string_literal: true

class CircleIntegration < Integration
  INTEGRATION_DETAILS = %w[community_id space_group_id]
  INTEGRATION_DETAILS.each { |detail| attr_json_data_accessor detail }

  validates_presence_of :api_key

  def as_json(*)
    super.merge(api_key:)
  end

  def self.is_enabled_for(purchase)
    purchase.find_enabled_integration(Integration::CIRCLE).present?
  end

  def self.connection_settings
    super + %w[api_key keep_inactive_members]
  end
end
