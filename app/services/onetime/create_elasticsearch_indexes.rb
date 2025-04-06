# frozen_string_literal: true

# This service creates the necessary Elasticsearch indexes
# Can be run as a one-time task to ensure all indexes exist

class Onetime::CreateElasticsearchIndexes < Onetime::Base
  def self.run(options = {})
    new.process_with_logging
  end

  def process
    puts "Creating missing Elasticsearch indexes..."

    # Create the confirmed_follower_events index
    create_confirmed_follower_events_index

    # Create product_page_views index
    create_product_page_views_index

    puts "Elasticsearch indexes creation complete!"
  end

  private

  def create_confirmed_follower_events_index
    puts "Creating confirmed_follower_events index..."
    if index_exists?("confirmed_follower_events")
      puts "Index confirmed_follower_events already exists."
    else
      # Create the index with proper settings
      begin
        ConfirmedFollowerEvent.__elasticsearch__.create_index!(index: "confirmed_follower_events_v1")
        EsClient.indices.put_alias(name: "confirmed_follower_events", index: "confirmed_follower_events_v1")
        puts "Index confirmed_follower_events created successfully."
      rescue => e
        puts "Error creating confirmed_follower_events index: #{e.message}"
      end
    end
  end

  def create_product_page_views_index
    puts "Creating product_page_views index..."
    if index_exists?("product_page_views")
      puts "Index product_page_views already exists."
    else
      # Create the index with proper settings
      begin
        ProductPageView.__elasticsearch__.create_index!
        puts "Index product_page_views created successfully."
      rescue => e
        puts "Error creating product_page_views index: #{e.message}"
      end
    end
  end

  def index_exists?(index_name)
    begin
      EsClient.indices.exists?(index: index_name)
    rescue => e
      puts "Error checking if index #{index_name} exists: #{e.message}"
      false
    end
  end
end
