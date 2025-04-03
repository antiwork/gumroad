# frozen_string_literal: true

class CreateTeamMemberships < ActiveRecord::Migration[6.1]
  def change
    create_table :team_memberships do |t|
      t.bigint :seller_id, null: false
      t.bigint :user_id, null: false
      t.string :role, null: false
      t.datetime :last_accessed_at
      t.datetime :deleted_at
      t.timestamps

      t.index [:seller_id]
      t.index [:user_id]
    end
  end
end
