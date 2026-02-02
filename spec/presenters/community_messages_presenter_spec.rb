# frozen_string_literal: true

require "spec_helper"

RSpec.describe CommunityMessagesPresenter do
  let(:seller) { create(:named_seller) }
  let(:buyer) { create(:user) }
  let(:community) { create(:community, seller:) }
  let(:current_user) { seller }

  describe "#props" do
    context "with no messages" do
      let(:presenter) { described_class.new(community:, current_user:) }

      it "returns empty messages array" do
        props = presenter.props

        expect(props[:messages]).to eq([])
        expect(props[:next_older_timestamp]).to be_nil
        expect(props[:next_newer_timestamp]).to be_nil
      end
    end

    context "with messages" do
      let!(:old_message) { create(:community_chat_message, community:, user: buyer, created_at: 3.days.ago) }
      let!(:middle_message) { create(:community_chat_message, community:, user: seller, created_at: 2.days.ago) }
      let!(:new_message) { create(:community_chat_message, community:, user: buyer, created_at: 1.day.ago) }

      context "when direction is 'around'" do
        let(:presenter) { described_class.new(community:, current_user:, cursor: middle_message.created_at.iso8601, direction: "around") }

        it "returns messages around the cursor" do
          props = presenter.props

          expect(props[:messages].length).to be >= 1
          expect(props[:current_cursor]).to eq(middle_message.created_at.iso8601)
        end
      end

      context "when direction is 'older'" do
        let(:presenter) { described_class.new(community:, current_user:, cursor: new_message.created_at.iso8601, direction: "older") }

        it "returns older messages" do
          props = presenter.props

          message_ids = props[:messages].map { |m| m[:id] }
          expect(message_ids).to include(old_message.external_id)
          expect(message_ids).to include(middle_message.external_id)
        end
      end

      context "when direction is 'newer'" do
        let(:presenter) { described_class.new(community:, current_user:, cursor: old_message.created_at.iso8601, direction: "newer") }

        it "returns newer messages" do
          props = presenter.props

          message_ids = props[:messages].map { |m| m[:id] }
          expect(message_ids).to include(middle_message.external_id)
          expect(message_ids).to include(new_message.external_id)
        end
      end
    end

    context "with last read message" do
      let!(:messages) { create_list(:community_chat_message, 3, community:, user: buyer) }
      let!(:last_read) do
        LastReadCommunityChatMessage.set!(
          user_id: current_user.id,
          community_id: community.id,
          community_chat_message_id: messages.second.id
        )
      end

      it "uses last read timestamp as default cursor when no cursor provided" do
        presenter = described_class.new(community:, current_user:)
        props = presenter.props

        expect(props[:current_cursor]).to eq(messages.second.created_at.iso8601)
      end
    end

    context "with deleted messages" do
      let!(:active_message) { create(:community_chat_message, community:, user: buyer) }
      let!(:deleted_message) { create(:community_chat_message, community:, user: buyer, deleted_at: Time.current) }

      let(:presenter) { described_class.new(community:, current_user:) }

      it "excludes deleted messages" do
        props = presenter.props

        message_ids = props[:messages].map { |m| m[:id] }
        expect(message_ids).to include(active_message.external_id)
        expect(message_ids).not_to include(deleted_message.external_id)
      end
    end

    context "pagination" do
      let!(:messages) do
        (1..150).map do |i|
          create(:community_chat_message, community:, user: buyer, created_at: i.hours.ago)
        end
      end

      let(:presenter) { described_class.new(community:, current_user:, direction: "older", cursor: Time.current.iso8601) }

      it "limits results to MESSAGES_PER_PAGE" do
        props = presenter.props

        expect(props[:messages].length).to eq(CommunityMessagesPresenter::MESSAGES_PER_PAGE)
      end

      it "provides next_older_timestamp when more messages exist" do
        props = presenter.props

        expect(props[:next_older_timestamp]).to be_present
      end
    end
  end
end
