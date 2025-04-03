# frozen_string_literal: true

require "spec_helper"

describe User::DeviseInternal do
  before do
    @user = create(:user, confirmed_at: nil)
  end

  describe "#confirmation_required?" do
    it "returns true if email is required" do
      allow(@user).to receive(:email_required?).and_return(true)
      allow(@user).to receive(:platform_user?).and_return(false)
      expect(@user.confirmation_required?).to be(true)
    end

    it "returns false if email is not required" do
      allow(@user).to receive(:email_required?).and_return(false)
      expect(@user.confirmation_required?).to be(false)
    end
  end
end
