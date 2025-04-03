# frozen_string_literal: true

require "spec_helper"

describe Iffy::Post::FlagService do
  describe "#perform" do
    let(:user) { create(:user) }
    let(:post) { create(:installment, seller: user, published_at: Time.current) }
    let(:service) { described_class.new(post.external_id) }

    it "unpublishes the post and sets is_unpublished_by_admin to true" do
      service.perform
      post.reload
      expect(post.published_at).to be_nil
      expect(post.is_unpublished_by_admin?).to be true
    end
  end
end
