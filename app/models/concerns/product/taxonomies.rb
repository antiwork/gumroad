# frozen_string_literal: true

module Product::Taxonomies
  extend ActiveSupport::Concern
  include Purchase::Searchable::ProductCallbacks

  included do
    belongs_to :taxonomy, optional: true

    # Runs after the files/taxonomy that feed a classifier's signals have had a chance to land,
    # not on every save — `save_taxonomy_attribute_values`/`save_inferred_taxonomy_attribute_values`
    # themselves call `save`, so an unconditional after_commit here would recurse.
    after_commit :classify_taxonomy_attributes, if: -> { saved_change_to_taxonomy_id? && persisted? }
  end

  private
    def classify_taxonomy_attributes
      Discover::TaxonomyAttributeClassifier.classify!(self)
    end
end
