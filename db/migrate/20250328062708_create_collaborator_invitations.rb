# frozen_string_literal: true

class CreateCollaboratorInvitations < ActiveRecord::Migration[7.1]
  def change
    create_table :collaborator_invitations do |t|
      t.belongs_to :collaborator, null: false, foreign_key: false, index: { unique: true }

      t.timestamps
    end
  end
end
