# frozen_string_literal: true

class RemoveDeliveredAtIndexFromEmailInfos < ActiveRecord::Migration[8.1]
  INDEX = "index_email_infos_on_installment_id_and_delivered_at"

  # Never built in production, so there this only records the version.
  def up
    return if Rails.env.production?

    remove_index :email_infos, name: INDEX, if_exists: true
  end

  def down
    return if Rails.env.production?

    add_index :email_infos, [:installment_id, :delivered_at], name: INDEX, if_not_exists: true
  end
end
