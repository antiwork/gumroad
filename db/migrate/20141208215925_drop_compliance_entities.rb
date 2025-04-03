# frozen_string_literal: true

class DropComplianceEntities < ActiveRecord::Migration
  def change
    drop_table :compliance_entities
  end
end
