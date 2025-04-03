# frozen_string_literal: true

class RemoveArchivedAtFromAffiliates < ActiveRecord::Migration[7.1]
  def change
    remove_column :affiliates, :archived_at, :datetime
  end
end
