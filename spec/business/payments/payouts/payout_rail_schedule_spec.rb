# frozen_string_literal: true

require "spec_helper"

describe PayoutRailSchedule do
  before { described_class.reset_cache! }
  after { described_class.reset_cache! }

  describe ".weekday_for_bank_account_type" do
    it "maps a cross-border bank account to the Tuesday run" do
      expect(described_class.weekday_for_bank_account_type("PhilippinesBankAccount")).to eq :tuesday
    end

    it "maps a non-US bank account to the Wednesday run" do
      expect(described_class.weekday_for_bank_account_type("UkBankAccount")).to eq :wednesday
    end

    it "maps a US bank account to the Thursday run" do
      expect(described_class.weekday_for_bank_account_type("AchAccount")).to eq :thursday
    end

    it "falls back to Friday for a bank account type that is in no payout run" do
      expect(described_class.weekday_for_bank_account_type("NotARealBankAccount")).to eq :friday
    end
  end

  it "maps PayPal and Stripe Connect payouts to the Friday runs" do
    expect(described_class.paypal_weekday).to eq :friday
    expect(described_class.stripe_connect_weekday).to eq :friday
  end

  it "covers every bank account type that a payout run pays out" do
    scheduled_types = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml")).each_value.flat_map do |entry|
      next [] unless entry["class"] == described_class::PAYOUT_WORKER_CLASS
      _processor_type, bank_account_types = Array(entry["args"])
      Array(bank_account_types)
    end

    expect(scheduled_types).to be_present
    scheduled_types.each do |bank_account_type|
      expect(described_class.weekday_for_bank_account_type(bank_account_type)).to be_in(described_class::WEEKDAYS)
    end
  end

  it "reads the weekday from the schedule rather than a hardcoded list" do
    # Proves the mapping cannot drift from the cron file: point the loader at a schedule that
    # moves a rail to a different weekday and the answer moves with it.
    allow(YAML).to receive(:load_file).and_return(
      "payouts_made_up_rail" => {
        "cron" => "0 10 * * 1 # UTC 10:00 MON",
        "class" => described_class::PAYOUT_WORKER_CLASS,
        "args" => ["STRIPE", ["PhilippinesBankAccount"]]
      }
    )
    described_class.reset_cache!

    expect(described_class.weekday_for_bank_account_type("PhilippinesBankAccount")).to eq :monday
  end
end
