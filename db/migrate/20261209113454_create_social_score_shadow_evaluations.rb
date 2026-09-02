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

      t.index [:user_id, :evaluated_on], unique: true
      t.index [:evaluated_on, :would_have_released]
    end
  end
end
