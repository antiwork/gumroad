# frozen_string_literal: true

module Installment::Searchable
  extend ActiveSupport::Concern

  included do
    include Elasticsearch::Model
    include SearchIndexModelCommon
    include ElasticsearchModelAsyncCallbacks

    index_name "installments"

    settings number_of_shards: 1, number_of_replicas: 0, index: {
      analysis: {
        filter: {
          autocomplete_filter: {
            type: "edge_ngram",
            min_gram: 1,
            max_gram: 20,
            token_chars: %w[letter digit]
          }
        },
        analyzer: {
          name: {
            tokenizer: "whitespace",
            filter: %w[lowercase autocomplete_filter]
          },
          search_name: {
            tokenizer: "whitespace",
            filter: "lowercase"
          },
          message: {
            tokenizer: "whitespace",
            filter: "lowercase",
            char_filter: ["html_strip"]
          },
          search_message: {
            tokenizer: "whitespace",
            filter: "lowercase",
            char_filter: ["html_strip"]
          }
        }
      }
    }

    mapping dynamic: :strict do
      indexes :id, type: :long
      indexes :message, type: :text, analyzer: :message, search_analyzer: :search_message
      indexes :name, type: :text, analyzer: :name, search_analyzer: :search_name
      indexes :seller_id, type: :long
      indexes :workflow_id, type: :long
      indexes :created_at, type: :date
      indexes :deleted_at, type: :date
      indexes :published_at, type: :date
      indexes :selected_flags, type: :keyword
    end

    ATTRIBUTE_TO_SEARCH_FIELDS = {
      "id" => "id",
      "name" => "name",
      "message" => "message",
      "seller_id" => "seller_id",
      "workflow_id" => "workflow_id",
      "created_at" => "created_at",
      "deleted_at" => "deleted_at",
      "published_at" => "published_at",
      "flags" => "selected_flags",
    }

    def search_field_value(field_name)
      case field_name
      when "selected_flags"
        selected_flags.map(&:to_s)
      else
        attributes[field_name]
      end.as_json
    end
  end
end
