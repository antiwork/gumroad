# frozen_string_literal: true

require "spec_helper"

describe Event do
  describe "post view" do
    before do
      link = create(:product, name: "product name")
      @post = create(:installment, link:)
      @post_view_event = create(:post_view_event)
      @installment_event = create(:installment_event, event_id: @post_view_event.id, installment_id: @post.id)
    end

    it "creates the post_view event with the right values" do
      expect(@post_view_event.event_name).to eq "post_view"
      expect(@installment_event.installment_id).to eq @post.id
      expect(@installment_event.event_id).to eq @post_view_event.id
    end

    it "is counted for in the scopes" do
      expect(Event.post_view.count).to eq 1
    end
  end
end
