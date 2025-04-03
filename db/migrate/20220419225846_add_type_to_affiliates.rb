# frozen_string_literal: true

class AddTypeToAffiliates < ActiveRecord::Migration[6.1]
  def change
    add_column :affiliates, :type, :string, null: false, default: "DirectAffiliate"
  end
end
