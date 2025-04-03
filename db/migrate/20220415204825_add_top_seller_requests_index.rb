# frozen_string_literal: true

class AddTopSellerRequestsIndex < ActiveRecord::Migration[6.1]
  def up
    if Rails.env.production? || Rails.env.staging?
      TopSellerRequest.__elasticsearch__.create_index!(index: "top_seller_requests_v1")
      EsClient.indices.put_alias(name: "top_seller_requests", index: "top_seller_requests_v1")
    else
      TopSellerRequest.__elasticsearch__.create_index!
    end
  end

  def down
    if Rails.env.production? || Rails.env.staging?
      EsClient.indices.delete_alias(name: "top_seller_requests", index: "top_seller_requests_v1")
      TopSellerRequest.__elasticsearch__.delete_index!(index: "top_seller_requests_v1")
    else
      TopSellerRequest.__elasticsearch__.delete_index!
    end
  end
end
