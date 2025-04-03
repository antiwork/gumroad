# frozen_string_literal: true

require "spec_helper"

RSpec.describe LastReadCommunityChatMessage do
  subject(:last_read_message) { build(:last_read_community_chat_message) }

  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:community) }
    it { is_expected.to belong_to(:community_chat_message) }
  end

  describe "validations" do
    it { is_expected.to validate_uniqueness_of(:user_id).scoped_to(:community_id) }
  end

  describe ".set!" do
    let(:user) { create(:user) }
    let(:community) { create(:community) }
    let(:message1) { create(:community_chat_message, community: community, created_at: 1.hour.ago) }
    let(:message2) { create(:community_chat_message, community: community, created_at: Time.current) }

    context "when no record exists" do
      it "creates a new record" do
        expect do
          described_class.set!(
            user_id: user.id,
            community_id: community.id,
            community_chat_message_id: message1.id
          )
        end.to change(described_class, :count).by(1)
      end
    end

    context "when record already exists" do
      before do
        create(
          :last_read_community_chat_message,
          user:,
          community:,
          community_chat_message: message1
        )
      end

      context "when given message is newer than existing message" do
        it "updates the record" do
          expect do
            described_class.set!(
              user_id: user.id,
              community_id: community.id,
              community_chat_message_id: message2.id
            )
          end.not_to change(described_class, :count)

          last_read = described_class.find_by!(user:, community:)
          expect(last_read.community_chat_message_id).to eq(message2.id)
        end
      end

      context "when given message is older than existing message" do
        let(:message2) { create(:community_chat_message, community: community, created_at: 2.hours.ago) }

        it "does not update the record" do
          expect do
            described_class.set!(
              user_id: user.id,
              community_id: community.id,
              community_chat_message_id: message2.id
            )
          end.not_to change(described_class, :count)

          last_read = described_class.find_by!(user:, community:)
          expect(last_read.community_chat_message_id).to eq(message1.id)
        end
      end
    end
  end

  describe ".unread_count_for" do
    let(:user) { create(:user) }
    let(:community) { create(:community) }
    let!(:message1) { create(:community_chat_message, community: community, created_at: 3.hours.ago) }
    let!(:message2) { create(:community_chat_message, community: community, created_at: 2.hours.ago) }
    let!(:message3) { create(:community_chat_message, community: community, created_at: 1.hour.ago) }

    context "when last read record exists" do
      before do
        create(
          :last_read_community_chat_message,
          user:,
          community:,
          community_chat_message: message1
        )
      end

      it "returns count of messages newer than the last read message" do
        count = described_class.unread_count_for(
          user_id: user.id,
          community_id: community.id
        )

        expect(count).to eq(2)
      end

      it "returns count using provided message if specified" do
        count = described_class.unread_count_for(
          user_id: user.id,
          community_id: community.id,
          community_chat_message_id: message2.id
        )

        expect(count).to eq(1)
      end
    end

    context "when no last read record exists" do
      it "returns count of all messages in the community" do
        count = described_class.unread_count_for(
          user_id: user.id,
          community_id: community.id
        )

        expect(count).to eq(3)
      end
    end

    context "when messages are deleted" do
      before do
        create(
          :last_read_community_chat_message,
          user:,
          community:,
          community_chat_message: message1
        )
        message2.mark_deleted!
      end

      it "only counts alive messages" do
        count = described_class.unread_count_for(
          user_id: user.id,
          community_id: community.id
        )

        expect(count).to eq(1)
      end
    end
  end
end
