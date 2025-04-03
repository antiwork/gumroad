# frozen_string_literal: true

class ProductPageView
  include Elasticsearch::Model

  index_name "product_page_views"

  def self.index_name_from_body(body)
    USE_ES_ALIASES ? "#{index_name}-#{body["timestamp"].first(7)}" : index_name
  end

  settings number_of_shards: 1, number_of_replicas: 0

  mapping dynamic: :strict do
    indexes :product_id, type: :long
    indexes :country, type: :keyword
    indexes :state, type: :keyword
    indexes :referrer_domain, type: :keyword
    indexes :timestamp, type: :date
    indexes :seller_id, type: :long
    indexes :user_id, type: :long
    indexes :ip_address, type: :keyword
    indexes :url, type: :keyword
    indexes :browser_guid, type: :keyword
    indexes :browser_fingerprint, type: :keyword
    indexes :referrer, type: :keyword
  end
end
