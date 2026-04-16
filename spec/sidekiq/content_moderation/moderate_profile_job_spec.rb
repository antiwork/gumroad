# frozen_string_literal: true

require "spec_helper"

RSpec.describe ContentModeration::ModerateProfileJob do
  describe "#perform" do
    it "finds the user and delegates to the moderation service" do
      user = create(:user)
      service = instance_double(ContentModeration::ModerateRecordService, perform: true)

      expect(ContentModeration::ModerateRecordService).to receive(:new).with(user, :profile).and_return(service)

      described_class.new.perform(user.id)
    end
  end
end
