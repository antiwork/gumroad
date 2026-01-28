# frozen_string_literal: true

class RemoveNullContraintFromUpsellName < ActiveRecord::Migration[4.2]
  def change
    change_column_null :upsells, :name, true
  end
end
