# frozen_string_literal: true

class BackfillInstallmentsEventsCacheCount < ActiveRecord::Migration
  def up
    Installment.find_in_batches do |installments|
      # installment_events_count can be zero here instead of precalculated because we know
      # the installment_events table is empty.
      Installment.where(id: installments.map(&:id)).update_all(installment_events_count: 0)
      sleep(0.01)
    end
  end
end
