# frozen_string_literal: true

module ElasticsearchModelAsyncCallbacks
  extend ActiveSupport::Concern
  include TransactionalAttributeChangeTracker

  included do
    after_commit lambda { send_to_elasticsearch("index") }, on: :create
    after_commit lambda { send_to_elasticsearch("update") }, on: :update
    after_commit lambda { send_to_elasticsearch("delete") }, on: :destroy

    private
      def send_to_elasticsearch(action)
        options = { "record_id" => id, "class_name" => self.class.name }
        if action == "update"
          fields = self.class::ATTRIBUTE_TO_SEARCH_FIELDS.values_at(*attributes_committed).flatten.uniq.compact
          return if fields.empty?
          options["fields"] = fields
        end

        delay = action == "index" ? 2.seconds : 4.seconds
        ElasticsearchIndexerWorker.perform_in(delay, action, options)

        # Mitigation of small replica lag issues:
        ElasticsearchIndexerWorker.perform_in(3.minutes, action, options) if action.in?(%w[index update])
      end
  end
end
