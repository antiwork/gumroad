# frozen_string_literal: true

class DropDocuments < ActiveRecord::Migration[4.2]
  def change
    drop_table :documents
  end
end
