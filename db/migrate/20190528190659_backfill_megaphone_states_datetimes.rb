# frozen_string_literal: true

class BackfillMegaphoneStatesDatetimes < ActiveRecord::Migration
  def up
    MegaphoneState.find_in_batches do |records|
      now = Time.current
      MegaphoneState.where(id: records.map(&:id)).update_all(created_at: now, updated_at: now)
      sleep(0.1)
    end
  end
end
