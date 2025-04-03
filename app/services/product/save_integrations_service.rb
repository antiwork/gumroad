# frozen_string_literal: true

class Product::SaveIntegrationsService
  attr_reader :product, :integration_params

  def self.perform(*args)
    new(*args).perform
  end

  def initialize(product, integration_params = {})
    @product = product
    @integration_params = integration_params
  end

  def perform
    enabled_integrations = []

    if integration_params
      Integration::ALL_NAMES.each do |name|
        params_for_type = integration_params.dig(name)
        if params_for_type
          integration = product.find_integration_by_name(name)
          integration_class = Integration.class_for(name)
          integration = integration_class.new if integration.blank?
          # TODO: :product_edit_react cleanup
          integration_details = params_for_type.delete(:integration_details) || {}
          integration.assign_attributes(
            **params_for_type.slice(
              *integration_class.connection_settings,
              *integration_class::INTEGRATION_DETAILS,
            ),
            **integration_details.slice(*integration_class::INTEGRATION_DETAILS)
          )
          integration.save!
          enabled_integrations << integration
        end
      end
    end

    other_products_by_user = Link.where(user_id: product.user_id).alive.where.not(id: product.id).pluck(:id)
    integrations_on_other_products = Integration.joins(:product_integration).where("product_integration.product_id" => other_products_by_user, "product_integration.deleted_at" => nil)

    deleted_integrations = product.active_integrations - enabled_integrations
    deletion_successful = product.live_product_integrations.where(integration: deleted_integrations).reduce(true) do |success, product_integration|
      integration = product_integration.integration
      same_connection_exists = integrations_on_other_products.find { |other_integration| integration.same_connection?(other_integration) }
      disconnection_successful = same_connection_exists ? true : integration.disconnect!

      if disconnection_successful
        product_integration.mark_deleted
        success
      else
        product.errors.add(:base, "Could not disconnect the #{integration.name.tr("_", " ")} integration, please try again.")
        false
      end
    end
    raise Link::LinkInvalid unless deletion_successful

    product.active_integrations << enabled_integrations - product.active_integrations
  end
end
