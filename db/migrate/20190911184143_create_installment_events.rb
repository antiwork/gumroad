# frozen_string_literal: true

class CreateInstallmentEvents < ActiveRecord::Migration
  def up
    create_table :installment_events do |t|
      t.references :event, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.references :installment, index: { unique: true }, foreign_key: { on_delete: :cascade }
    end
  end

  def down
    drop_table :installment_events
  end
end
