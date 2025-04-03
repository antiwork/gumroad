# frozen_string_literal: true

require "spec_helper"

RSpec.describe CommunityPresenter do
  let(:seller) { create(:named_seller) }
  let(:buyer) { create(:user) }
  let(:community) { create(:community, seller:) }
  let(:presenter) { described_class.new(community:, current_user: buyer) }

  describe "#props" do
    subject(:props) { presenter.props }

    it "returns appropriate props" do
      expect(props).to eq(
        id: community.external_id,
        name: community.name,
        thumbnail_url: community.thumbnail_url,
        seller: {
          id: seller.external_id,
          name: seller.display_name,
          avatar_url: seller.avatar_url,
        },
        last_read_community_chat_message_created_at: nil,
        unread_count: 0,
      )
    end

    context "when extras are provided" do
      let(:last_read_at) { 1.day.ago }
      let(:unread_count) { 5 }
      let(:presenter) do
        described_class.new(
          community:,
          current_user: buyer,
          extras: {
            last_read_community_chat_message_created_at: last_read_at.iso8601,
            unread_count:,
          }
        )
      end

      it "uses the provided values instead of querying the database" do
        expect(props[:last_read_community_chat_message_created_at]).to eq(last_read_at.iso8601)
        expect(props[:unread_count]).to eq(unread_count)
      end
    end

    context "when there are unread messages" do
      let!(:message1) { create(:community_chat_message, community:, user: seller, created_at: 3.minutes.ago) }
      let!(:message2) { create(:community_chat_message, community:, user: seller, created_at: 2.minutes.ago) }
      let!(:message3) { create(:community_chat_message, community:, user: seller, created_at: 1.minute.ago) }
      let!(:last_read) do
        create(:last_read_community_chat_message, user: buyer, community:, community_chat_message: message1)
      end

      it "returns the last read message timestamp" do
        expect(props[:last_read_community_chat_message_created_at]).to eq(message1.created_at.iso8601)
      end

      it "returns the correct unread count" do
        expect(props[:unread_count]).to eq(2)
      end
    end
  end
end
