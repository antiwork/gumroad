# frozen_string_literal: true

class Page < ApplicationRecord
  MAX_CUSTOM_HTML_LENGTH = 500_000

  belongs_to :pageable, polymorphic: true, touch: true
  validates :custom_html, length: { maximum: MAX_CUSTOM_HTML_LENGTH }
end
