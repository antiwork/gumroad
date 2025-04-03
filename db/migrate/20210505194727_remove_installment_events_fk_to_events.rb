# frozen_string_literal: true

class RemoveInstallmentEventsFkToEvents < ActiveRecord::Migration[6.1]
  def up
    remove_foreign_key :installment_events, :events
  end

  def down
    add_foreign_key :installment_events, :events, name: "_fk_rails_674b6b1780", on_delete: :cascade
  end
end
