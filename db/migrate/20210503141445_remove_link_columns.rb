# frozen_string_literal: true

class RemoveLinkColumns < ActiveRecord::Migration[6.1]
  def up
    change_table :links do |t|
      t.remove :territory_restriction
      t.remove :preview_automatically_generated
      t.remove :bad_email_counter
      t.remove :preview_processed
      t.remove :webhook_fail_count
      t.remove :preview_attachment_id
      t.remove :partner_source
      t.remove :is_charitable
      t.remove :custom_download_text
    end
  end

  def down
    change_table :links do |t|
      t.text :territory_restriction, size: :medium
      t.boolean :preview_automatically_generated
      t.integer :bad_email_counter, default: 0
      t.integer :webhook_fail_count, default: 0
      t.boolean :preview_processed, default: true
      t.integer :preview_attachment_id
      t.string :partner_source
      t.boolean :is_charitable, default: false
      t.string :custom_download_text
    end
  end
end
