# frozen_string_literal: true

class DropComplianceEntities < ActiveRecord::Migration[4.2]
  def change
    drop_table :compliance_entities
  end
end
