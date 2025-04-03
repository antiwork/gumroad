# frozen_string_literal: true

class DiscoverSearch < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :taxonomy, optional: true
  belongs_to :clicked_resource, polymorphic: true, optional: true

  has_one :discover_search_suggestion
end
