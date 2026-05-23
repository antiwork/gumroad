# frozen_string_literal: true

require "test_helper"

class TipTest < ActiveSupport::TestCase
  self.described_class = Tip


  context_ Tip do
  context_ "validations" do
  context_ "when value_cents is greater than 0" do
  test "doesn't add an error" do
          tip = build(:tip, value_cents: 100)
          expect(tip).to be_valid
        end
      end

  context_ "when value_cents is zero" do
  test "adds an error" do
          tip = build(:tip, value_cents: 0)
          expect(tip).not_to be_valid
          expect(tip.errors[:value_cents]).to include("must be greater than 0")
        end
      end
    end
  end
end
