# frozen_string_literal: true

require "spec_helper"

describe Exports::AudienceExportService do
  describe "#perform" do
    before do
      @user = create(:user)
      @follower = create(:active_follower, email: "follower@gumroad.com", user: @user)
    end

    it "generates csv with followers" do
      csv = Exports::AudienceExportService.new(@user).perform
      expect(csv).to include "follower@gumroad.com"
    end
  end
end
