# frozen_string_literal: true

# users is frozen (docs/migrations.md). Live YouTube identity lives here so
# connect/unlink does not ALTER that table.
class CreateUserYoutubeIdentities < ActiveRecord::Migration[7.1]
  def change
    create_table :user_youtube_identities do |t|
      t.references :user, null: false, index: { unique: true }
      t.string :channel_id, null: false
      t.string :handle
      t.timestamps

      t.index :channel_id
    end
  end
end
