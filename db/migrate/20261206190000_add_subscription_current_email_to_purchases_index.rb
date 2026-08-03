# frozen_string_literal: true

class AddSubscriptionCurrentEmailToPurchasesIndex < ActiveRecord::Migration[7.1]
  def up
    EsClient.indices.put_mapping(
      index: Purchase.index_name,
      body: {
        properties: {
          subscription_current_email: {
            type: "text",
            analyzer: "email",
            search_analyzer: "search_email",
            fields: {
              raw: { type: "keyword" }
            }
          },
          subscription_current_email_domain: {
            type: "text",
            analyzer: "email",
            search_analyzer: "search_email"
          }
        }
      }
    )
  end
end
