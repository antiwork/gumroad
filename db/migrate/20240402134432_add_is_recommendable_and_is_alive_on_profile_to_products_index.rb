# frozen_string_literal: true

class AddIsRecommendableAndIsAliveOnProfileToProductsIndex < ActiveRecord::Migration[7.1]
  def up
    EsClient.indices.put_mapping(
      index: Link.index_name,
      body: {
        properties: {
          is_recommendable: { type: "boolean" },
          is_alive_on_profile: { type: "boolean" },
        }
      }
    )
  end
end
