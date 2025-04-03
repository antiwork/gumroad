# frozen_string_literal: true

class ConfirmedFollowerEvent
  include Elasticsearch::Model
  index_name "confirmed_follower_events"

  settings(
    number_of_shards: 1,
    number_of_replicas: 0,
    sort: { field: :timestamp, order: :asc }
  )

  mapping dynamic: :strict do
    indexes :name, type: :keyword
    indexes :timestamp, type: :date
    indexes :follower_id, type: :long
    indexes :followed_user_id, type: :long
    indexes :follower_user_id, type: :long
    indexes :email, type: :keyword
  end

  module Events
    ADDED = "added"
    REMOVED = "removed"
    ADDED_AND_REMOVED = [ADDED, REMOVED]
  end

  module FollowerCallbacks
    extend ActiveSupport::Concern
    include ConfirmedFollowerEvent::Events

    included do
      after_commit :create_confirmed_follower_event
    end

    def create_confirmed_follower_event
      # This method only handles the change of confirmation state
      return unless confirmed_at_previous_change&.any?(&:nil?)

      job_params = {
        class_name: "ConfirmedFollowerEvent",
        id: SecureRandom.uuid,
        body: {
          follower_id: id,
          followed_user_id: followed_id,
          follower_user_id:,
          email:
        }
      }

      if confirmed_at_previously_was.blank?
        job_params[:body].merge!(name: ADDED, timestamp: confirmed_at.iso8601)
      else
        job_params[:body].merge!(name: REMOVED, timestamp: deleted_at.iso8601)
      end

      ElasticsearchIndexerWorker.perform_async("index", job_params.deep_stringify_keys)
    end
  end
end
