# frozen_string_literal: true

require "test_helper"

class MoneyFormatterTest < ActiveSupport::TestCase
  self.described_class = MoneyFormatter


  context_ MoneyFormatter do
  context_ "#format" do
  context_ "usd" do
  test "returns the correct string" do
          expect(MoneyFormatter.format(400, :usd)).to eq "$4.00"
        end

  test "returns correctly when no symbol desired" do
          expect(MoneyFormatter.format(400, :usd, symbol: false)).to eq "4.00"
        end
      end

  context_ "jpy" do
  test "returns the correct string" do
          expect(MoneyFormatter.format(400, :jpy)).to eq "¥400"
        end
      end

  context_ "aud" do
  test "returns the correct currency symbol" do
          expect(MoneyFormatter.format(400, :aud)).to eq "A$4.00"
        end
      end
    end
  end
end
