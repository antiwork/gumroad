# frozen_string_literal: true

require "spec_helper"

describe ContentModerationAdminCommentJob do
  let(:seller) { create(:user) }
  let(:content) { "Content moderation blocked publish of Post #123 (Title): spam: repetitive CTAs" }

  describe "#perform" do
    it "creates a moderation note on the user" do
      expect do
        described_class.new.perform(seller.id, content)
      end.to change { seller.reload.comments.count }.by(1)

      comment = seller.comments.last
      expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_NOTE)
      expect(comment.author_name).to eq(ContentModeration::ModerateRecordService::AUTHOR_NAME)
      expect(comment.content).to eq(content)
    end

    it "does not duplicate an identical note within the dedup window" do
      described_class.new.perform(seller.id, content)

      expect do
        described_class.new.perform(seller.id, content)
      end.not_to change { seller.reload.comments.count }
    end

    it "creates a fresh note once the dedup window has elapsed" do
      described_class.new.perform(seller.id, content)

      travel_to(ContentModeration::ModerateRecordService::ADMIN_COMMENT_DEDUP_WINDOW.from_now + 1.second) do
        expect do
          described_class.new.perform(seller.id, content)
        end.to change { seller.reload.comments.count }.by(1)
      end
    end

    it "creates separate notes for different contents within the window" do
      described_class.new.perform(seller.id, content)

      expect do
        described_class.new.perform(seller.id, "#{content} (different)")
      end.to change { seller.reload.comments.count }.by(1)
    end

    it "no-ops when the user no longer exists" do
      expect do
        described_class.new.perform(-1, content)
      end.not_to change { Comment.count }
    end
  end
end
