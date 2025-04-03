# frozen_string_literal: true

describe Tip do
  describe "validations" do
    context "when value_cents is greater than 0" do
      it "doesn't add an error" do
        tip = build(:tip, value_cents: 100)
        expect(tip).to be_valid
      end
    end

    context "when value_cents is zero" do
      it "adds an error" do
        tip = build(:tip, value_cents: 0)
        expect(tip).not_to be_valid
        expect(tip.errors[:value_cents]).to include("must be greater than 0")
      end
    end
  end
end
