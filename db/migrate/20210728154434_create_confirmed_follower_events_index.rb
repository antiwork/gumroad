# frozen_string_literal: true

class CreateConfirmedFollowerEventsIndex < ActiveRecord::Migration[6.1]
  def up
    if Rails.env.production? || Rails.env.staging?
      ConfirmedFollowerEvent.__elasticsearch__.create_index!(index: "confirmed_follower_events_v1")
      EsClient.indices.put_alias(name: "confirmed_follower_events", index: "confirmed_follower_events_v1")
    else
      ConfirmedFollowerEvent.__elasticsearch__.create_index!
    end
  end

  def down
    if Rails.env.production? || Rails.env.staging?
      EsClient.indices.delete_alias(name: "confirmed_follower_events", index: "confirmed_follower_events_v1")
      ConfirmedFollowerEvent.__elasticsearch__.delete_index!(index: "confirmed_follower_events_v1")
    else
      ConfirmedFollowerEvent.__elasticsearch__.delete_index!
    end
  end
end
