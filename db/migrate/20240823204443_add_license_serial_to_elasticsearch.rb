# frozen_string_literal: true

class AddLicenseSerialToElasticsearch < ActiveRecord::Migration[7.1]
  def up
    EsClient.indices.put_mapping(
      index: Purchase.index_name,
      body: {
        properties: {
          license_serial: { type: "keyword" },
        }
      }
    )
  end
end
