# frozen_string_literal: true

# Main already records a future schema version, so this timestamp must sort
# after it; the time component is the real UTC authoring time, so parallel
# branches do not collide on a shared hand-picked value.
class CreateSocialScoreShadowEvaluations < ActiveRecord::Migration[7.1]
  def change
    create_table :social_score_shadow_evaluations do |t|
      t.bigint :user_id, null: false
      t.date :evaluated_on, null: false
      t.string :hold_source, null: false
      t.bigint :unpaid_balance_cents, null: false
      t.integer :score, null: false
      t.boolean :would_have_released, null: false, default: false
      t.json :signals
      t.timestamps

      # Explicit name: the Rails default for this pair exceeds the 62-byte
      # auto-name limit and would get an opaque idx_on_<sha> name instead.
      t.index [:user_id, :evaluated_on], unique: true, name: "index_sse_on_user_id_and_evaluated_on"
      t.index [:evaluated_on, :would_have_released], name: "index_sse_on_evaluated_on_and_would_have_released"
    end
  end
end
