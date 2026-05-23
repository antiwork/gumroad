# frozen_string_literal: true

require "test_helper"

class UserDeviseInternalTest < ActiveSupport::TestCase
  self.described_class = User::DeviseInternal



  context_ User::DeviseInternal do
    before do
      @user = create(:user, confirmed_at: nil)
    end

  context_ "#confirmation_required?" do
  test "returns true if email is required" do
        allow(@user).to receive(:email_required?).and_return(true)
        allow(@user).to receive(:platform_user?).and_return(false)
        expect(@user.confirmation_required?).to be(true)
      end

  test "returns false if email is not required" do
        allow(@user).to receive(:email_required?).and_return(false)
        expect(@user.confirmation_required?).to be(false)
      end
    end
  end
end
