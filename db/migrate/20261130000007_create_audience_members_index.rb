# frozen_string_literal: true

class CreateAudienceMembersIndex < ActiveRecord::Migration[7.1]
  def up
    if Rails.env.production? || Rails.env.staging?
      # The model's 1-shard/0-replica settings are sized for dev and test;
      # production needs replica redundancy and shards small enough to relocate.
      AudienceMember.__elasticsearch__.create_index!(
        index: "audience_members_v1",
        settings: AudienceMember.settings.to_hash.merge(number_of_shards: 4, number_of_replicas: 1)
      )
      EsClient.indices.put_alias(name: "audience_members", index: "audience_members_v1")
    else
      AudienceMember.__elasticsearch__.create_index!
    end
  end

  def down
    if Rails.env.production? || Rails.env.staging?
      EsClient.indices.delete_alias(name: "audience_members", index: "audience_members_v1")
      AudienceMember.__elasticsearch__.delete_index!(index: "audience_members_v1")
    else
      AudienceMember.__elasticsearch__.delete_index!
    end
  end
end
