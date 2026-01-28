# frozen_string_literal: true

class ChangeInstallmentsEventsCacheCountDefault < ActiveRecord::Migration[4.2]
  def up
    change_column_default :installments, :installment_events_count, 0
  end

  def down
    change_column_default :installments, :installment_events_count, nil
  end
end
