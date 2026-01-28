# frozen_string_literal: true

class RemoveArchivedAtFromAffiliates < ActiveRecord::Migration[4.2]
  def change
    remove_column :affiliates, :archived_at, :datetime
  end
end
