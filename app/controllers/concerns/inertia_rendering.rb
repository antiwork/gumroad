# frozen_string_literal: true

module InertiaRendering
  extend ActiveSupport::Concern
  include ApplicationHelper
  include CurrencyHelper

  included do
    # Opt-in per action, because the share below costs a GeoIP lookup per request. List the actions
    # whose pages mount a footer currency selector; everything else (the dashboard, and the seller
    # actions that sit on the same controllers) skips it.
    class_attribute :buyer_currency_footer_actions, default: [].freeze, instance_writer: false

    inertia_share do
      RenderingExtension.custom_context(view_context).merge(
        authenticity_token: form_authenticity_token,
        flash: inertia_flash_props,
        title: page_title
      )
    end

    # IP-detected presentment currency, for the footer selector's default and its "— detected" label.
    inertia_share if: -> { buyer_currency_footer_actions.include?(action_name) } do
      { detected_buyer_currency: buyer_currency_for_ip(request.remote_ip) }
    end

    inertia_share if: :user_signed_in? do
      {
        current_user: current_user_props(current_user, impersonated_user),
        prompt_passkey_setup: show_passkey_setup_prompt?
      }
    end
  end

  private
    def inertia_flash_props
      return if (flash_message = flash[:alert] || flash[:warning] || flash[:notice]).blank?

      { message: flash_message, status: flash[:alert] ? "danger" : flash[:warning] ? "warning" : "success" }
    end

    def inertia_errors(model)
      { errors: model.errors.to_hash.each_with_object({}) do |(key, messages), hash|
        hash["#{model.model_name.element}.#{key}"] = messages.to_sentence
      end }
    end
end
