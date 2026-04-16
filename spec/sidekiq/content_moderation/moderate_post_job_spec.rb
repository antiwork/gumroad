# frozen_string_literal: true

require "spec_helper"

RSpec.describe ContentModeration::ModeratePostJob do
  describe "#perform" do
    it "finds the post and delegates to the moderation service" do
      post = create(:audience_post)
      service = instance_double(ContentModeration::ModerateRecordService, perform: true)

      expect(ContentModeration::ModerateRecordService).to receive(:new).with(post, :post).and_return(service)

      described_class.new.perform(post.id)
    end
  end
end
