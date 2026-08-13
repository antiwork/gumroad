# frozen_string_literal: true

# Main already records a future schema version, so this timestamp must sort
# after it; the time component is the real UTC authoring time, so parallel
# branches do not collide on a shared hand-picked value.
class CreateGumheadUsageEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :gumhead_usage_events do |t|
      t.bigint :user_id, null: false
      t.string :model, null: false
      t.bigint :input_tokens, null: false, default: 0
      t.bigint :output_tokens, null: false, default: 0
      t.bigint :cache_creation_input_tokens, null: false, default: 0
      t.bigint :cache_creation_1h_input_tokens, null: false, default: 0
      t.bigint :cache_read_input_tokens, null: false, default: 0
      t.timestamps

      t.index [:user_id, :created_at]
    end
  end
end
