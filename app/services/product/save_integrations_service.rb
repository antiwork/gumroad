# frozen_string_literal: true

class Product::SaveIntegrationsService
  attr_reader :product, :integration_params, :contract

  def self.perform(*args, **kwargs)
    new(*args, **kwargs).perform
  end

  def initialize(product, integration_params = {}, contract: nil)
    @product = product
    @integration_params = integration_params
    @contract = contract
  end

  def perform
    # Product::SaveContract, Rule 1: a request that did not submit
    # `integrations` (absent or empty — the two are deliberately
    # indistinguishable) and carries no explicit deletion for them must leave
    # every active integration exactly as it is. This is the single most
    # dangerous collection to get wrong: the diff-and-delete pass below ends
    # in `integration.disconnect!`, a live call to the third-party provider
    # (Discord bot removal, Google OAuth token revocation, ...) with no undo.
    # Before this guard, an omitted `integrations` key — including one dropped
    # by strong parameters because the value was malformed — disconnected
    # everything. Returning early, before any diffing, is the conservative
    # reading: we don't even compute what "would" be deleted.
    return if contract_enforced? && no_integrations_intent?

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

    deleted_integrations = integrations_to_delete(enabled_integrations)
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

  private
    def contract_enforced?
      contract.present? && contract.enforced?
    end

    # True when this request expressed no intent about integrations at all:
    # the collection wasn't submitted (absent and {} read the same, Rule 1)
    # and no explicit deletion targets it. `submitted?` is presence-based, so
    # an empty hash — the shape strong parameters produces when every entry
    # is malformed — also counts as "not submitted".
    def no_integrations_intent?
      !contract.submitted?(:integrations) &&
        contract.deleted_ids(:integrations).empty? &&
        !contract.cleared?(:integrations)
    end

    # Which active integrations may this save disconnect?
    #
    # Without the contract: the historical diff — anything active that this
    # payload didn't re-submit (byte-identical to the old behaviour).
    #
    # With the contract: only explicit asks (Rule 2). Integrations have no
    # external id exposed to the editor; the collection is keyed by provider
    # name everywhere (params, Integration::ALL_NAMES), so deleted_ids for
    # this collection are provider names ("discord", "circle", ...).
    # Deliberately NOT intersected with the submitted diff: an explicit
    # deletion stands on its own, and an implicit diff never deletes.
    def integrations_to_delete(enabled_integrations)
      implicit = product.active_integrations - enabled_integrations
      # Flag lookup failed: we cannot tell whether the contract governs this
      # save, and this diff calls integration.disconnect! — an irreversible
      # third-party API call. Guessing "delete" here is unrecoverable, guessing
      # "keep" costs a stale row the seller can remove again. See
      # Product::SaveContract#degraded?.
      return [] if contract&.degraded?
      return implicit unless contract_enforced?

      return implicit if contract.cleared?(:integrations) # clear-all: everything not re-submitted goes

      names_to_delete = contract.deleted_ids(:integrations)
      product.active_integrations.select { _1.name.in?(names_to_delete) } - enabled_integrations
    end
end
