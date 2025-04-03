# frozen_string_literal: true

class RemoveImportJobs < ActiveRecord::Migration[6.0]
  def up
    drop_table :import_jobs
  end

  def down
    create_table "import_jobs", id: :integer, options: "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci", force: :cascade do |t|
      t.string "import_file_url", limit: 255
      t.integer "user_id"
      t.integer "link_id"
      t.string "state", limit: 255
      t.datetime "created_at"
      t.datetime "updated_at"
    end
  end
end
