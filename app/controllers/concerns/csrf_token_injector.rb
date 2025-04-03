# frozen_string_literal: true

module CsrfTokenInjector
  extend ActiveSupport::Concern

  TOKEN_PLACEHOLDER = "_CROSS_SITE_REQUEST_FORGERY_PROTECTION_TOKEN__"

  included do
    after_action :inject_csrf_token
  end

  def inject_csrf_token
    token = form_authenticity_token
    return if !protect_against_forgery?

    body_with_token = response.body.gsub!(TOKEN_PLACEHOLDER, token)
    response.body = body_with_token if body_with_token
  end
end
