# frozen_string_literal: true

unless ENV["LOG_ES"] == "true"
  EsClient.transport.logger = Logger.new(File::NULL)
end

module Elasticsearch::API::Actions
  alias original_index index
  def index_and_wait_for_refresh(arguments = {})
    arguments[:refresh] = "true"
    original_index(arguments)
  end

  alias original_update update
  def update_and_wait_for_refresh(arguments = {})
    arguments[:refresh] = "true"
    original_update(arguments)
  end

  alias original_update_by_query update_by_query
  def update_by_query_and_wait_for_refresh(arguments = {})
    arguments[:refresh] = true
    original_update_by_query(arguments)
  end

  alias original_delete delete
  def delete_and_wait_for_refresh(arguments = {})
    arguments[:refresh] = "true"
    original_delete(arguments)
  end
end

module ElasticsearchHelpers
  def recreate_model_index(model)
    model.__elasticsearch__.create_index!(force: true)
  end
  alias recreate_model_indices recreate_model_index

  def index_model_records(model)
    model.import(refresh: true, force: true)
  end
end

class ElasticsearchSetup
  def self.recreate_index(model)
    model.__elasticsearch__.delete_index!(force: true)
    while model.__elasticsearch__.create_index!.nil?
      puts "Waiting to recreate ES index '#{model.index_name}' ..."
      model.__elasticsearch__.delete_index!(force: true)
      sleep 0.1
    end
  end

  def self.prepare_test_environment
    # Check that ES is ready, with 1 minute of total grace period
    6.times do |i|
      EsClient.info
    rescue Errno::ECONNREFUSED, Faraday::ConnectionFailed => e
      puts "[Try: #{i}] ES is not ready (#{e.message})"
      sleep 1
    else
      break # on success, break out of this loop
    end

    # Ensure indices are ready: same settings, same mapping, zero documents
    models = [Link, Balance, Purchase, Installment, ConfirmedFollowerEvent, ProductPageView]
    models.each do |model|
      model.index_name("#{model.name.parameterize}-test")
    end

    all_mappings_and_settings = EsClient.indices.get(index: models.map(&:index_name), ignore_unavailable: true)

    models.each do |model|
      # If the index doesn't exist, create it
      unless all_mappings_and_settings.key?(model.index_name)
        recreate_index(model)
        next
      end

      normalized_local_mappings = model.mappings.to_hash.deep_stringify_keys.deep_transform_values(&:to_s)
      remote_mappings = all_mappings_and_settings[model.index_name]["mappings"].deep_transform_values(&:to_s)
      normalized_local_settings = model.settings.to_hash.deep_stringify_keys.deep_transform_values(&:to_s)
      normalized_local_settings.merge!(normalized_local_settings.delete("index") || {}).deep_transform_values(&:to_s)
      remote_settings = all_mappings_and_settings[model.index_name]["settings"]["index"].except("provided_name", "uuid", "creation_date", "version")

      # If the settings or mappings are different, recreate the index
      if normalized_local_mappings != remote_mappings || normalized_local_settings != remote_settings
        puts "[ES] Recreating index #{model.index_name} (model: #{model.name}), because its settings or mappings changed. " \
        "If you modified them, please remember to write a migration to update the index in development/staging/production environments."
        recreate_index(model)
        next
      end

      # In case there are any documents, empty the index and refresh
      10.times do |i|
        EsClient.delete_by_query(index: model.index_name, conflicts: "abort", body: { query: { match_all: {} } })
      rescue Elasticsearch::Transport::Transport::Errors::Conflict => e
        puts "[Try: #{i}] Failed to empty index for #{model.index_name} due to conflicts (#{e.message})"
        sleep 1
      else
        break # on success, break out of this loop
      end
      model.__elasticsearch__.refresh_index!
    end
  end
end
