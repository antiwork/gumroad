# frozen_string_literal: true

class AddRecurringPaymentMethodContextToCreditCards < ActiveRecord::Migration[7.1]
  # Renumbered three times: off 20261206000015 (already in production's schema_migrations, like
  # 20261206000017 and 20261206000019), then off 20261206000021 when main's
  # add_notification_claim_to_subscription_plan_changes took that version, then off 20261206000023
  # when main's create_product_permalink_redirects landed at 20261206000024. At a burned number
  # db:migrate skips this silently and deploys green with the columns absent, and recurring_upi?
  # reads payment_method_type on every saved-card charge, so the whole renewal fleet raises.
  COLUMNS = {
    payment_method_type: :string,
    stripe_account_id: :string,
    recurring_authorization_verified_at: :datetime,
    recurring_authorization_currency: :string,
    recurring_authorization_max_amount_cents: :integer
  }.freeze

  def up
    missing = COLUMNS.reject { |name, _| column_exists?(:credit_cards, name) }
    return if missing.empty?

    change_table :credit_cards, bulk: true do |t|
      missing.each { |name, type| t.column name, type }
    end
  end

  def down
    present = COLUMNS.keys.select { |name| column_exists?(:credit_cards, name) }
    return if present.empty?

    change_table :credit_cards, bulk: true do |t|
      present.each { |name| t.remove name }
    end
  end
end
