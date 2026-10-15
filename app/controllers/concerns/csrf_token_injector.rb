# frozen_string_literal: true

module CsrfTokenInjector
  extend ActiveSupport::Concern

  TOKEN_PLACEHOLDER = "_CROSS_SITE_REQUEST_FORGERY_PROTECTION_TOKEN__"

  SAFE_INSERTION_SELECTOR = /(<meta\s+name=["']csrf-token["']\s+content=["'])#{Regexp.escape(TOKEN_PLACEHOLDER)}(["'])/i

  def rewrite_csrf_token(html, token)
    return html unless html
    html.gsub(SAFE_INSERTION_SELECTOR) { "#{$1}#{token}#{$2}" }
  end

  included do
    after_action :inject_csrf_token
  end

  def inject_csrf_token
    # Reading a Live response's body drains its stream, including the end marker that Puma
    # waits for, so the request never finishes and its Puma thread stays blocked.
    return if response.stream.is_a?(ActionController::Live::Buffer)

    token = form_authenticity_token
    return if !protect_against_forgery?

    rewritten_body = rewrite_csrf_token(response.body, token)
    response.body = rewritten_body if rewritten_body != response.body
  end
end
