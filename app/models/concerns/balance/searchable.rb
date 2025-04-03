# frozen_string_literal: true

module Balance::Searchable
  extend ActiveSupport::Concern

  included do
    include Elasticsearch::Model
    include SearchIndexModelCommon
    include ElasticsearchModelAsyncCallbacks

    index_name "balances"

    settings number_of_shards: 1, number_of_replicas: 0

    mapping dynamic: :strict do
      indexes :amount_cents, type: :long
      indexes :user_id, type: :long
      indexes :state, type: :keyword
    end

    ATTRIBUTE_TO_SEARCH_FIELDS = {
      "amount_cents" => "amount_cents",
      "user_id" => "user_id",
      "state" => "state"
    }

    def search_field_value(field_name)
      case field_name
      when "amount_cents", "user_id", "state"
        attributes[field_name]
      end.as_json
    end
  end

  class_methods do
    def amount_cents_sum_for(user)
      query = Elasticsearch::DSL::Search.search do
        size 0
        query do
          bool do
            filter do
              term user_id: user.id
            end
            filter do
              term state: "unpaid"
            end
          end
        end
        aggregation :sum_amount_cents do
          sum field: "amount_cents"
        end
      end
      __elasticsearch__.search(query).aggregations.sum_amount_cents.value.to_i
    end
  end
end
