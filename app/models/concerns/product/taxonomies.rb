# frozen_string_literal: true

module Product::Taxonomies
  extend ActiveSupport::Concern
  include Purchase::Searchable::ProductCallbacks

  included do
    belongs_to :taxonomy, optional: true
  end
end
