# frozen_string_literal: true

class CreateAudienceMembersIndex < ActiveRecord::Migration[7.1]
  def up
    if Rails.env.production? || Rails.env.staging?
      AudienceMember.__elasticsearch__.create_index!(index: "audience_members_v1")
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
