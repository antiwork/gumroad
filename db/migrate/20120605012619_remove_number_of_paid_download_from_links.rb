# frozen_string_literal: true

class RemoveNumberOfPaidDownloadFromLinks < ActiveRecord::Migration[4.2]
  def up
    remove_column :links, :number_of_paid_downloads
  end

  def down
    add_column :links, :number_of_paid_downloads, :integer
  end
end
