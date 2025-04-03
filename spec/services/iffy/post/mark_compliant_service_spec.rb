# frozen_string_literal: true

require "spec_helper"

describe Iffy::Post::MarkCompliantService do
  describe "#perform" do
    let(:user) { create(:user) }
    let(:post) { create(:installment, seller: user) }
    let(:service) { described_class.new(post.external_id) }

    it "publishes the post if it is unpublished by admin" do
      post.unpublish!(is_unpublished_by_admin: true)
      expect(post.published_at).to be_nil
      expect(post.is_unpublished_by_admin?).to be true

      service.perform

      post.reload
      expect(post.published_at).to be_present
      expect(post.is_unpublished_by_admin?).to be false
    end

    it "does not publish the post if it is unpublished but not by admin" do
      post.unpublish!(is_unpublished_by_admin: false)
      expect(post.published_at).to be_nil
      expect(post.is_unpublished_by_admin?).to be false

      service.perform

      post.reload
      expect(post.published_at).to be_nil
      expect(post.is_unpublished_by_admin?).to be false
    end

    context "when the post is already published" do
      let(:post) { create(:installment, seller: user, published_at: Time.current) }

      it "does not change the post's published status" do
        expect(post.published_at).to be_present

        service.perform

        expect(post.reload.published_at).to be_present
      end
    end
  end
end
