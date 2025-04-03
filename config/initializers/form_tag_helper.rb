# frozen_string_literal: true

ActionView::Helpers::CsrfHelper.class_eval do
  def csrf_meta_tags
    return unless protect_against_forgery?

    [
      tag(:meta, name: "csrf-param", content: request_forgery_protection_token),
      tag(:meta, name: "csrf-token", content: ApplicationController::TOKEN_PLACEHOLDER)
    ].join("\n").html_safe
  end
end
