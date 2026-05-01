# frozen_string_literal: true

require "spec_helper"

describe User::CreateAdminCommentService do
  let(:user) { create(:user) }
  let(:admin_user) { create(:admin_user) }

  before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

  describe "#perform" do
    it "creates a comment with COMMENT_TYPE_NOTE attributed to GUMROAD_ADMIN_ID" do
      comment = described_class.new(user:, content: "Note from support", idempotency_key: "key-1").perform

      expect(comment).to be_persisted
      expect(comment.content).to eq("Note from support")
      expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_NOTE)
      expect(comment.author_id).to eq(admin_user.id)
      expect(comment.idempotency_key).to eq("key-1")
      expect(comment.commentable).to eq(user)
    end

    it "creates a comment attributed to the supplied author" do
      actor = create(:admin_user)

      comment = described_class.new(user:, content: "Note from support", idempotency_key: "key-1", author_id: actor.id).perform

      expect(comment).to be_persisted
      expect(comment.author_id).to eq(actor.id)
    end

    it "returns the existing comment when called twice with the same idempotency key and matching content" do
      first = described_class.new(user:, content: "Same content", idempotency_key: "dup").perform
      second = described_class.new(user:, content: "Same content", idempotency_key: "dup").perform

      expect(second.id).to eq(first.id)
      expect(user.comments.where(idempotency_key: "dup").count).to eq(1)
    end

    it "raises IdempotencyConflictError when an existing key is reused with different content" do
      described_class.new(user:, content: "Original", idempotency_key: "shared").perform

      expect do
        described_class.new(user:, content: "Different", idempotency_key: "shared").perform
      end.to raise_error(described_class::IdempotencyConflictError)
    end

    it "returns a comment with errors when validation fails" do
      invalid = described_class.new(user:, content: "", idempotency_key: "invalid").perform

      expect(invalid).not_to be_persisted
      expect(invalid.errors).to be_present
    end
  end
end
