# frozen_string_literal: true

class AddTaxonomyAttributeFiltersToProductsIndex < ActiveRecord::Migration[7.1]
  def up
    EsClient.indices.put_mapping(
      index: Link.index_name,
      body: {
        properties: {
          taxonomy_attribute_filters: { type: "keyword" },
        }
      }
    )
  end
end
