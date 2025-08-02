# frozen_string_literal: true

class AddStatusToAffiliates < ActiveRecord::Migration[7.0]
  def change
    add_column :affiliates, :status, :string, default: 'approved', null: false
    add_index :affiliates, :status
    
    # Set existing affiliates to approved status
    reversible do |dir|
      dir.up do
        execute "UPDATE affiliates SET status = 'approved' WHERE deleted_at IS NULL"
      end
    end
  end
end
