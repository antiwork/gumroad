# frozen_string_literal: true

# Balance and BalanceTransaction refuse a Gumroad-held row that is not USD. Specs that model rows
# written before that check existed (repair services, payout guards) build them inside this block.
module LegacyGumroadHeldRows
  # For a whole example (call from a `before` hook).
  def allow_legacy_gumroad_held_rows
    allow_any_instance_of(BalanceTransaction).to receive(:validate_gumroad_held_amounts_are_usd)
    allow_any_instance_of(Balance).to receive(:validate_gumroad_held_amounts_are_usd)
  end

  # For setup only; the check is back on for the rest of the example.
  def writing_legacy_gumroad_held_rows
    allow_legacy_gumroad_held_rows
    yield
  ensure
    allow_any_instance_of(BalanceTransaction).to receive(:validate_gumroad_held_amounts_are_usd).and_call_original
    allow_any_instance_of(Balance).to receive(:validate_gumroad_held_amounts_are_usd).and_call_original
  end
end

RSpec.configure do |config|
  config.include LegacyGumroadHeldRows
end
