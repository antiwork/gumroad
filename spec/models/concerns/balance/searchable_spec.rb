# frozen_string_literal: true

require "spec_helper"

describe Balance::Searchable do
  describe "#as_indexed_json" do
    let(:balance) { create(:balance, amount_cents: 123, state: "unpaid") }

    it "includes all fields" do
      expect(balance.as_indexed_json).to eq(
        "user_id" => balance.user_id,
        "amount_cents" => 123,
        "state" => "unpaid"
      )
    end

    it "allows only a selection of fields to be used" do
      expect(balance.as_indexed_json(only: ["amount_cents"])).to eq(
        "amount_cents" => 123
      )
    end
  end

  describe ".amount_cents_sum_for", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    before do
      @user_1 = create(:user)
      @user_2 = create(:user)
    end

    it "returns sum of unpaid balance in cents" do
      create(:balance, user: @user_1, amount_cents: 100, state: "unpaid", date: 1.day.ago)
      create(:balance, user: @user_2, amount_cents: 100, state: "unpaid", date: 2.days.ago)
      create(:balance, user: @user_1, amount_cents: 150, state: "unpaid", date: 3.days.ago)
      create(:balance, user: @user_1, amount_cents: 150, state: "paid", date: 4.days.ago)

      expect(Balance.amount_cents_sum_for(@user_1)).to eq(250)
      expect(Balance.amount_cents_sum_for(@user_2)).to eq(100)
    end
  end
end
