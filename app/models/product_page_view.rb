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

  # Add Elasticsearch index creation methods
  def self.create_index!
    client = __elasticsearch__.client

    # Delete index if it already exists
    begin
      client.indices.delete index: index_name
    rescue => e
      puts "Could not delete index #{index_name}: #{e.message}" if defined?(Rails) && Rails.env.development?
    end

    # Create index with settings and mappings
    client.indices.create(
      index: index_name,
      body: {
        settings: settings.to_hash,
        mappings: mappings.to_hash
      }
    )

    puts "Created Elasticsearch index: #{index_name}" if defined?(Rails) && Rails.env.development?
  end

  # Mock search method for empty index
  def self.search(options={})
    # If index doesn't exist, create it first
    begin
      __elasticsearch__.client.indices.get(index: index_name)
    rescue Elasticsearch::Transport::Transport::Errors::NotFound
      create_index!
    end

    # Forward to the actual search
    __elasticsearch__.search(options)
  end
end
