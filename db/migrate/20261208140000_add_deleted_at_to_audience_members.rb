# frozen_string_literal: true

class AddDeletedAtToAudienceMembers < ActiveRecord::Migration[7.1]
  def change
    add_column :audience_members, :deleted_at, :datetime, null: true
  end
end
