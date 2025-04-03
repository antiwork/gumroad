# frozen_string_literal: true

class DiscoverSearchSuggestion < ApplicationRecord
  include Deletable

  belongs_to :discover_search

  scope :by_user_or_browser, ->(user:, browser_guid:) {
    alive
      .joins(:discover_search)
      .where(discover_searches: user.present? ? { user: } : { browser_guid:, user: nil })
      .order(created_at: :desc)
  }
end
