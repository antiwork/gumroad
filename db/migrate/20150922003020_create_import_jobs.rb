# frozen_string_literal: true

class CreateImportJobs < ActiveRecord::Migration
  def change
    create_table :import_jobs, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.string :import_file_url
      t.integer :user_id
      t.integer :link_id
      t.string :state
      t.integer :flags, default: 0, null: false

      t.timestamps
    end
  end
end
