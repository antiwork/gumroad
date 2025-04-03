# frozen_string_literal: true

class MigrateDeletedPurchases < ActiveRecord::Migration[7.0]
  def up
    return unless Rails.env.development?

    invalid_purchase_ids = []
    eligible_purchases.find_in_batches do |batch|
      batch.each do |purchase|
        purchase.update!(
          purchase_state: "successful",
          is_access_revoked: true
        )
      rescue StandardError => e
        invalid_purchase_ids << { purchase.id => e.message }
      end
    end
    if invalid_purchase_ids.present?
      puts("Could not migrate all purchases. Please migrate the following purchases manually")
      invalid_purchase_ids.each do |purchase_info|
        purchase_info.each { |id, error_message| puts "Purchase ID: #{id}, Error: #{error_message}" }
      end
    end
  end

  private
    def eligible_purchases
      Purchase.where("purchase_state = ?", "deleted")
    end
end
