# frozen_string_literal: true

require "spec_helper"
require "benchmark"

describe Admin::RelatedUsersService, :benchmark do
  def credit_card_with_fingerprint(fingerprint)
    CreditCard.create!(
      stripe_fingerprint: fingerprint,
      visual: "**** **** **** 4242",
      card_type: CardType::VISA,
      stripe_customer_id: "cus_#{SecureRandom.hex(6)}",
      expiry_month: 12,
      expiry_year: 2030,
      charge_processor_id: StripeChargeProcessor.charge_processor_id
    )
  end

  it "runs the related-users lookup under 500ms with realistic fan-out; run with bundle exec rspec --tag benchmark spec/services/admin/related_users_service_benchmark_spec.rb" do
    target = create(:user,
                    account_created_ip: "1.2.3.4",
                    current_sign_in_ip: "5.6.7.8",
                    last_sign_in_ip: nil,
                    payment_address: "benchmark-payment@example.com",
                    credit_card: credit_card_with_fingerprint("fp_benchmark"))

    200.times do |index|
      create(:user,
             account_created_ip: "198.51.100.#{index % 250}",
             current_sign_in_ip: nil,
             last_sign_in_ip: nil,
             payment_address: "unrelated-#{index}@example.com")
    end

    create_list(:user, 200, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil)
    create_list(:user, 200, account_created_ip: nil, current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: "benchmark-payment@example.com")

    200.times do
      create(:user,
             account_created_ip: nil,
             current_sign_in_ip: nil,
             last_sign_in_ip: nil,
             payment_address: nil,
             credit_card: credit_card_with_fingerprint("fp_benchmark"))
    end

    described_class.new(target).call
    duration = Benchmark.realtime { described_class.new(target).call }
    RSpec.configuration.reporter.message("Related users benchmark: #{(duration * 1000).round(1)}ms")

    expect(duration).to be < 0.5
  end
end
