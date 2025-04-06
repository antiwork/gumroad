# frozen_string_literal: true

namespace :elasticsearch do
  namespace :development do
    desc "Create all Elasticsearch indexes needed for development"
    task :create_indexes => :environment do
      # Models with Elasticsearch indexes
      models = [
        'ProductPageView',
        'Purchase',
        'Product',
        'Link'
      ]

      models.each do |model_name|
        begin
          puts "Creating index for #{model_name}..."
          klass = model_name.constantize
          if klass.respond_to?(:__elasticsearch__) && klass.respond_to?(:create_index!)
            begin
              klass.__elasticsearch__.client.indices.delete(index: klass.__elasticsearch__.index_name)
              puts "  - Deleted existing index"
            rescue
              puts "  - No existing index to delete"
            end

            klass.create_index!
            puts "  - Index created successfully"
          else
            puts "  - Model does not support Elasticsearch"
          end
        rescue => e
          puts "  - ERROR: #{e.message}"
        end
      end

      puts "Finished creating indexes"
    end
  end
end
