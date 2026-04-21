# frozen_string_literal: true

class AddLicenseUsesToElasticsearch < ActiveRecord::Migration[7.1]
  def up
    EsClient.indices.put_mapping(
      index: Purchase.index_name,
      body: {
        properties: {
          license_uses: { type: "long" },
        }
      }
    )
  end
end
