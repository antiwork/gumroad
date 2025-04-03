# frozen_string_literal: true

class ElasticsearchIndexerWorker
  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :default

  UPDATE_BY_QUERY_SCROLL_SIZE = 100

  # Usage examples:
  # .perform("index", { "class_name" => "Link", "record_id" => 1 } )
  # .perform("delete", { "class_name" => "Link", "record_id" => 1 } )
  # .perform("update", { "class_name" => "Link", "record_id" => 1, "fields" => ["price_cents"] } )
  # .perform("update_by_query", { "class_name" => "Link", "source_record_id" => 1, "fields" => ["price_cents"], "query" => {...} } )
  # .perform("index", { "class_name" => "SomeEvent", "id" => "0ab1c2", "body" => { "timestamp" => "2021-07-20T01:00:00Z" } } )
  def perform(operation, params)
    if operation == "update_by_query"
      if Feature.active?(:esiw_delay_ubqs)
        ElasticsearchIndexerWorker.perform_in(rand(72.hours) + 6.hours, operation, params)
        return
      else
        return perform_update_by_query(params)
      end
    end

    klass = params.fetch("class_name").constantize

    client_params = {
      index: klass.index_name,
      ignore: Set.new
    }
    client_params[:ignore] << 404 if ignore_404_errors_on_indices.include?(klass.index_name)

    if params.key?("record_id")
      record_id = params.fetch("record_id")
      client_params[:id] = record_id
    else
      client_params[:id] = params.fetch("id")
    end

    case operation
    when "index"
      client_params[:body] = params["body"] || klass.find(record_id).as_indexed_json
      client_params[:index] = klass.index_name_from_body(client_params[:body]) if klass.respond_to?(:index_name_from_body)
      EsClient.index(client_params)
    when "update"
      fields = params.fetch("fields")
      client_params[:body] = {
        "doc" => klass.find(record_id).as_indexed_json(only: fields)
      }
      EsClient.update(client_params)
    when "delete"
      client_params[:ignore] << 404
      EsClient.delete(client_params)
    end
  end

  def self.columns_to_fields(columns, mapping:)
    mapping.values_at(*columns).flatten.uniq.compact
  end

  private
    # The updates and deletion to the following index names will have 404 errors ignored.
    # This is useful when adding a new index and all records aren't indexed yet.
    # You can add an indice here by doing something like:
    # $redis.sadd(RedisKey.elasticsearch_indexer_worker_ignore_404_errors_on_indices, 'purchases_v2')
    def ignore_404_errors_on_indices
      $redis.smembers(RedisKey.elasticsearch_indexer_worker_ignore_404_errors_on_indices)
    end

    # Helps denormalization by enabling the update of a large amount of documents,
    # with the same values, selected via ES query.
    def perform_update_by_query(params)
      klass = params.fetch("class_name").constantize
      source_record = klass.find(params.fetch("source_record_id"))

      script = <<~SCRIPT.squish
        for (item in params.new_values) {
          ctx._source[item.key] = item.value;
        }
      SCRIPT
      new_values = []
      params.fetch("fields").map do |field|
        raise "Updating nested fields ('#{field}') by query is not supported" if field.include?(".")
        new_values << {
          key: field,
          value: source_record.search_field_value(field)
        }
      end

      # Most UBQ operate without conflicts, so let's try it directly first (faster and less expensive),
      # otherwise, scroll through results.
      begin
        EsClient.update_by_query(
          index: klass.index_name,
          body: {
            script: { source: script, params: { new_values: } },
            query: params.fetch("query")
          }
        )
      rescue Elasticsearch::Transport::Transport::Errors::Conflict, Faraday::TimeoutError => _e
        # noop
      else
        return
      end

      response = EsClient.search(
        index: klass.index_name,
        scroll: "1m",
        body: { query: params.fetch("query") },
        size: UPDATE_BY_QUERY_SCROLL_SIZE,
        sort: ["_doc"],
        _source: false
      )

      loop do
        hits = response.dig("hits", "hits")
        break if hits.empty?
        ids = hits.map { |hit| hit["_id"] }
        update_by_query_ids(
          index_name: klass.index_name,
          script:,
          script_params: { new_values: },
          ids:
        )
        break if hits.size < UPDATE_BY_QUERY_SCROLL_SIZE

        response = EsClient.scroll(
          index: klass.index_name,
          body: { scroll_id: response["_scroll_id"] },
          scroll: "1m"
        )
      end

      EsClient.clear_scroll(scroll_id: response["_scroll_id"])
    end

    def update_by_query_ids(index_name:, script:, script_params:, ids:)
      tries = 0
      max_retries = 10
      begin
        tries += 1
        EsClient.update_by_query(
          index: index_name,
          body: {
            script: { source: script, params: script_params },
            query: { terms: { _id: ids } }
          }
        )
      rescue Elasticsearch::Transport::Transport::Errors::Conflict => e
        raise e if tries == max_retries
        sleep 1
        retry
      end
    end
end
