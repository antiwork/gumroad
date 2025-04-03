# frozen_string_literal: true

module SearchIndexModelCommon
  extend ActiveSupport::Concern

  class_methods do
    def search_fields
      @_search_fields ||= mappings.to_hash[:properties].keys.map(&:to_s)
    end
  end

  def as_indexed_json(options = {})
    fields = options[:only] || self.class.search_fields
    fields.index_with { |field_name| search_field_value(field_name) }
  end
end
