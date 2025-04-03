# frozen_string_literal: true

class AddPdfStampEnabledToLinks < ActiveRecord::Migration
  def change
    add_column :links, :pdf_stamp_enabled, :boolean
  end
end
