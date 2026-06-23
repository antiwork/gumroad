# frozen_string_literal: true

class AddSubscriptionAndLicenseFieldsToAudienceMembersIndex < ActiveRecord::Migration[7.1]
  def up
    EsClient.indices.put_mapping(
      index: AudienceMember.index_name,
      body: {
        properties: {
          purchases: {
            type: "nested",
            properties: {
              subscription_cancelled: { type: "boolean" },
              license_uses: { type: "long" },
            }
          }
        }
      }
    )
  end
end
