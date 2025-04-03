# frozen_string_literal: true

class RemoveNullContraintFromUpsellName < ActiveRecord::Migration[7.1]
  def change
    change_column_null :upsells, :name, true
  end
end
