# frozen_string_literal: true

class RemovePdfStampEnabledFromLink < ActiveRecord::Migration[6.1]
  def change
    remove_column :links, :pdf_stamp_enabled, :boolean
  end
end
