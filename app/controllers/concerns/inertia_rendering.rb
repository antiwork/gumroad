# frozen_string_literal: true

module InertiaRendering
  extend ActiveSupport::Concern
  include ApplicationHelper

  included do
    inertia_share do
      RenderingExtension.custom_context(view_context).merge(
        authenticity_token: form_authenticity_token,
        flash: inertia_flash_props,
        title: @title
      )
    end

    inertia_share if: :user_signed_in? do
      { current_user: current_user_props(current_user, impersonated_user) }
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
