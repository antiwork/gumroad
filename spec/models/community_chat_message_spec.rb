# frozen_string_literal: true

require "spec_helper"

RSpec.describe CommunityChatMessage do
  subject(:community_chat_message) { build(:community_chat_message) }

  describe "associations" do
    it { is_expected.to belong_to(:community) }
    it { is_expected.to belong_to(:user) }
    it { is_expected.to have_many(:last_read_community_chat_messages).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:content) }
    it { is_expected.to validate_length_of(:content).is_at_least(1).is_at_most(20_000) }
  end

  describe "scopes" do
    describe ".recent_first" do
      it "returns messages in descending order of creation time" do
        community = create(:community)
        old_message = create(:community_chat_message, community: community, created_at: 2.days.ago)
        new_message = create(:community_chat_message, community: community, created_at: 1.day.ago)

        expect(CommunityChatMessage.recent_first).to eq([new_message, old_message])
      end
    end
  end
end
