# frozen_string_literal: true

require "test_helper"

class UserAustralianBacktaxesTest < ActiveSupport::TestCase
  self.described_class = User::AustralianBacktaxes



  context_ User::AustralianBacktaxes do
    before :each do
      @creator = create(:user)
    end

  context_ "#opted_in_to_australia_backtaxes?" do
  test "returns false if the creator hasn't opted in" do
        expect(@creator.opted_in_to_australia_backtaxes?).to eq(false)
      end

  test "returns true if the creator has opted in" do
        create(:backtax_agreement, user: @creator)
        expect(@creator.opted_in_to_australia_backtaxes?).to eq(true)
      end
    end

  context_ "#au_backtax_agreement_date" do
  test "returns nil if the creator hasn't opted in" do
        expect(@creator.au_backtax_agreement_date).to be_nil
      end

  test "returns the created_at date of the backtax_agreement if the creator has opted in" do
        backtax_agreement = create(:backtax_agreement, user: @creator)
        expect(@creator.au_backtax_agreement_date).to eq(backtax_agreement.created_at)
      end
    end

  context_ "#credit_creation_date" do
  test "returns July 1, 2023 as the earliest date" do
        travel_to(Time.find_zone("UTC").local(2023, 5, 5)) do
          expect(@creator.credit_creation_date).to eq("July 1, 2023")
        end
      end

  test "returns the first of the next month for anything after July 1, 2023" do
        travel_to(Time.find_zone("UTC").local(2023, 7, 5)) do
          expect(@creator.credit_creation_date).to eq("August 1, 2023")
        end
      end
    end
  end
end
