# frozen_string_literal: true

require "spec_helper"

describe "merchant account env probe" do
  it "reports merchant accounts for a fresh seller" do
    seller = create(:named_seller)
    accounts = seller.merchant_accounts.to_a
    puts "PROBE count=#{accounts.size}"
    accounts.each { |ma| puts "PROBE ma=#{ma.id} cp=#{ma.charge_processor_id} state=#{ma.state} errors=#{ma.errors.full_messages.inspect}" }
    puts "PROBE alive_count=#{seller.merchant_accounts.alive.count} cp_alive=#{seller.merchant_accounts.alive.charge_processor_alive.count}"
  rescue => e
    puts "PROBE raised=#{e.class}: #{e.message}"
  end
end