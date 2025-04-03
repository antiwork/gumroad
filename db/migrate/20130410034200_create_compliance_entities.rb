# frozen_string_literal: true

class CreateComplianceEntities < ActiveRecord::Migration
  def change
    create_table :compliance_entities do |t|
      t.string :source_list
      t.integer :entity_number
      t.string :sdn_type
      t.string :programs
      t.string :name
      t.string :title
      t.string :address
      t.string :city
      t.string :state_or_province
      t.string :postal_code
      t.string :country
      t.string :alternate_name

      t.timestamps
    end
    add_index :compliance_entities, :name
  end
end
