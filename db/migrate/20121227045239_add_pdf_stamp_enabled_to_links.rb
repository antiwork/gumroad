# frozen_string_literal: true

class AddPdfStampEnabledToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :pdf_stamp_enabled, :boolean
  end
end
