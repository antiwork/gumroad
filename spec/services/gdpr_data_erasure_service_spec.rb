# frozen_string_literal: true

require "spec_helper"

describe GdprDataErasureService do
  let(:user) { create(:user, name: "John Doe", bio: "My bio", street_address: "123 Main St", city: "New York", state: "NY", zip_code: "10001", country: "US") }
  let(:admin) { create(:user, name: "Admin") }

  describe "#perform!" do
    it "anonymizes user PII" do
      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:success]).to eq(true)
      user.reload
      expect(user.name).to eq("[deleted]")
      expect(user.email).to eq("deleted-#{user.id}@deleted.gumroad.com")
      expect(user.bio).to be_nil
      expect(user.street_address).to be_nil
      expect(user.city).to be_nil
      expect(user.state).to be_nil
      expect(user.zip_code).to be_nil
      expect(user.country).to be_nil
      expect(user.current_sign_in_ip).to be_nil
      expect(user.last_sign_in_ip).to be_nil
      expect(user.account_created_ip).to be_nil
      expect(user.deleted_at).to be_present
    end

    it "anonymizes buyer purchases" do
      purchase = create(:purchase, purchaser: user, full_name: "John Doe", street_address: "123 Main St")

      described_class.new(user, performed_by: admin).perform!

      purchase.reload
      expect(purchase.full_name).to eq("[deleted]")
      expect(purchase.street_address).to be_nil
    end

    it "deactivates the account and deletes products" do
      product = create(:product, user: user)

      described_class.new(user, performed_by: admin).perform!

      user.reload
      expect(user.deleted?).to eq(true)
      expect(product.reload.deleted?).to eq(true)
    end

    it "logs the erasure as a comment" do
      described_class.new(user, performed_by: admin).perform!

      comment = user.comments.last
      expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_NOTE)
      expect(comment.content).to include("GDPR data erasure performed")
      expect(comment.content).to include("GDPR data erasure performed")
    end

    it "returns external cleanup instructions" do
      result = described_class.new(user, performed_by: admin).perform!

      expect(result[:summary][:external_cleanup_needed]).to include("Helper/Supabase (customer conversations)")
      expect(result[:summary][:external_cleanup_needed]).to include("Stripe (customer data)")
    end
  end
end
