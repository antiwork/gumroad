# frozen_string_literal: true

# Main already records a future schema version, so this timestamp must sort
# after it; the time component is the real UTC authoring time, so parallel
# branches do not collide on a shared hand-picked value.
class AddYoutubeIdentityToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :youtube_channel_id, :string
    add_column :users, :youtube_handle, :string
  end
end
