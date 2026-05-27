# frozen_string_literal: true

class Page < ApplicationRecord
  MAX_CUSTOM_HTML_LENGTH = 500_000

  belongs_to :pageable, polymorphic: true, touch: true
  validates :custom_html, length: { maximum: MAX_CUSTOM_HTML_LENGTH }

  # Safety net so every save path (internal dashboard, API v2, model writes)
  # ends up sanitized. The API v2 controller still calls sanitize_with_report
  # ahead of time so it can return the report; that's idempotent with this.
  before_save :sanitize_html

  private
    def sanitize_html
      return if custom_html.nil?

      self.custom_html = Ai::PageSanitizer.sanitize(custom_html).presence
    end
end
