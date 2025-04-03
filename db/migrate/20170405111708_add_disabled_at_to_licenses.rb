# frozen_string_literal: true

class AddDisabledAtToLicenses < ActiveRecord::Migration
  def change
    add_column :licenses, :disabled_at, :datetime
  end
end
