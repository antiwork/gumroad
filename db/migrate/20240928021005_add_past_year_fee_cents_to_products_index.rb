# frozen_string_literal: true

class AddPastYearFeeCentsToProductsIndex < ActiveRecord::Migration[7.1]
  def up
    EsClient.indices.put_mapping(
      index: Link.index_name,
      body: {
        properties: {
          past_year_fee_cents: { type: "long" },
        }
      }
    )
  end
end
