# frozen_string_literal: true

class FixInstallmentEventsIndexes < ActiveRecord::Migration
  def up
    change_table :installment_events do |t|
      t.remove_references :event, foreign_key: { on_delete: :cascade }
      t.remove_references :installment, foreign_key: { on_delete: :cascade }
      t.references :event, index: true, foreign_key: { on_delete: :cascade }
      t.references :installment, foreign_key: { on_delete: :cascade }
      t.index [:installment_id, :event_id], unique: true
    end
  end

  def down
    change_table :installment_events do |t|
      t.remove_references :event, foreign_key: { on_delete: :cascade }
      t.remove_references :installment, foreign_key: { on_delete: :cascade }
      t.references :event, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.references :installment, index: { unique: true }, foreign_key: { on_delete: :cascade }
    end
  end
end
