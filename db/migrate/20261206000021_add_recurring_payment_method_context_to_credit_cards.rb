# frozen_string_literal: true

class AddRecurringPaymentMethodContextToCreditCards < ActiveRecord::Migration[7.1]
  # Renumbered from 20261206000015, which production's schema_migrations already records — see
  # 20261206000017 and 20261206000019, both renumbered off that same version. At the old number
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
