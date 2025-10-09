# frozen_string_literal: true

module InertiaRendering
  extend ActiveSupport::Concern
  include ApplicationHelper

  included do
    inertia_share do
      RenderingExtension.custom_context(view_context).merge(
        current_user: current_user_props(current_user, impersonated_user),
        authenticity_token: form_authenticity_token,
        flash: inertia_flash_props,
        title: @title
      )
    end
  end

  private
    def inertia_flash_props
      return if (flash_message = flash[:alert] || flash[:warning] || flash[:notice]).blank?

      { message: flash_message, status: flash[:alert] ? "alert" : flash[:warning] ? "warning" : "success" }
    end
end
