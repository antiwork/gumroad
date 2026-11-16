# frozen_string_literal: true

class AddDeliveredAtIndexToEmailInfos < ActiveRecord::Migration[8.1]
  INDEX = "index_email_infos_on_installment_id_and_delivered_at"

  # Delivery reads filter one installment's rows by delivered_at (antiwork/gumroad-private#2723),
  # which the (installment_id, purchase_id) index does not contain.
  #
  # Built by hand in production with pt-osc: at this table's size the copy cannot ride a deploy,
  # so there the deploy only records this version.
  def up
    return if Rails.env.production?

    add_index :email_infos, [:installment_id, :delivered_at], name: INDEX
  end

  def down
    return if Rails.env.production?

    remove_index :email_infos, name: INDEX
  end
end
