# frozen_string_literal: true

class AddEmailDomainToPurchasesIndex < ActiveRecord::Migration[4.2]
  def up
    EsClient.indices.put_mapping(
      index: Purchase.index_name,
      body: {
        properties: {
          email_domain: { type: "text", analyzer: "email", search_analyzer: "search_email" }
        }
      }
    )
  end
end
