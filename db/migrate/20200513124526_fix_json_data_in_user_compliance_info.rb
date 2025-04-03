# frozen_string_literal: true

class FixJsonDataInUserComplianceInfo < ActiveRecord::Migration
  def up
    UserComplianceInfo.where(json_data: nil).find_in_batches(batch_size: 5000) do |relation|
      print "."
      UserComplianceInfo.where(id: relation.map(&:id)).update_all(json_data: {})
      sleep(0.01)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
