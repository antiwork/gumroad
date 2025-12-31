# frozen_string_literal: true

module InertiaRendering
  extend ActiveSupport::Concern
  include ApplicationHelper

  included do
    inertia_share do
      RenderingExtension.custom_context(view_context).merge(
        authenticity_token: form_authenticity_token,
        title: @title
      )
    end

    inertia_share if: :user_signed_in? do
      { current_user: current_user_props(current_user, impersonated_user) }
    end
  end
end
