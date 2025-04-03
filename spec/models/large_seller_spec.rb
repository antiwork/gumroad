# frozen_string_literal: true

require "spec_helper"

describe LargeSeller do
  before do
    @user = create(:user)
  end

  describe ".create_if_warranted" do
    it "doesn't create a record if large seller already exists" do
      create(:large_seller, user: @user)
      expect do
        described_class.create_if_warranted(@user)
      end.not_to change(LargeSeller, :count)
    end

    it "doesn't create a record if sales count below lower limit" do
      allow(@user).to receive(:sales).and_return(double(count: 90))
      expect do
        described_class.create_if_warranted(@user)
      end.not_to change(LargeSeller, :count)
    end

    it "creates a record if sales count above lower limit" do
      allow(@user).to receive(:sales).and_return(double(count: 7_000))
      expect do
        described_class.create_if_warranted(@user)
      end.to change(LargeSeller, :count)
      expect(@user.large_seller).to be_present
    end
  end
end
