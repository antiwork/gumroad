# frozen_string_literal: true

class CreateTeamInvitations < ActiveRecord::Migration[7.0]
  def change
    create_table :team_invitations do |t|
      t.bigint :seller_id, null: false
      t.string :email, null: false
      t.string :role, null: false
      t.timestamps
      t.datetime :expires_at, null: false
      t.datetime :accepted_at
      t.datetime :deleted_at

      t.index [:seller_id]
    end
  end
end
