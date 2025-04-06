# frozen_string_literal: true

# Fix for Elasticsearch import model loading order
# This ensures models are loaded in the correct order during imports

Rails.application.config.after_initialize do
  # Define our custom Elasticsearch import task that handles model dependencies correctly
  if defined?(Rake) && Rake.application.top_level_tasks.include?('elasticsearch:import:all')
    # Make sure fundamental models are loaded first
    Rails.logger.info "Preloading essential models for Elasticsearch import..."
    models_to_preload = [
      'bank_account',
      'user',
      'link',
      'payment',
      'purchase',
      'order'
    ]

    models_to_preload.each do |model|
      require_dependency Rails.root.join("app/models/#{model}.rb").to_s rescue nil
    end
  end
end

# Fix for missing Elasticsearch indexes in development
# This adds a simple method to check and create indexes if they don't exist
module ElasticsearchIndexManager
  def self.ensure_indexes_exist
    # Only run in development mode
    return unless Rails.env.development?

    # List of models that use Elasticsearch
    searchable_models = [
      'ProductPageView',
      'Purchase',
      'Product',
      'Link'
    ]

    # Try to create indexes for each model
    searchable_models.each do |model_name|
      begin
        model = model_name.constantize
        if model.respond_to?(:__elasticsearch__) && model.respond_to?(:create_index!)
          begin
            model.__elasticsearch__.client.indices.get(index: model.__elasticsearch__.index_name)
            Rails.logger.info "Index for #{model_name} already exists"
          rescue Elasticsearch::Transport::Transport::Errors::NotFound
            Rails.logger.info "Creating index for #{model_name}..."
            model.create_index!
          end
        end
      rescue => e
        Rails.logger.warn "Error checking/creating index for #{model_name}: #{e.message}"
      end
    end
  end
end

# Create indexes automatically if we're in development environment
if Rails.env.development?
  Rails.application.config.after_initialize do
    # Ensure indexes exist after application is initialized
    ElasticsearchIndexManager.ensure_indexes_exist
  end
end
