# frozen_string_literal: true

require "spec_helper"

describe Product::BulkUpdateSupportEmailService do
  let(:user) { create(:user) }

  let!(:product1) { create(:product, user:, support_email: "old1@example.com") }
  let!(:product2) { create(:product, user:, support_email: "old2@example.com") }
  let!(:product3) { create(:product, user:, support_email: "old3@example.com") }

  let(:other_user_product) { create(:product, support_email: "other@example.com") }

  before { Feature.activate_user(:product_level_support_emails, user) }

  describe "#perform" do
    it "updates products support emails according to entries" do
      entries = [
        { email: "new1+2@example.com", product_ids: [product1.external_id, product2.external_id] },
        { email: "new3@example.com", product_ids: [product3.external_id] }
      ]

      service = described_class.new(user, entries)

      expect { service.perform }
        .to change { product1.reload.support_email }.to("new1+2@example.com")
        .and change { product2.reload.support_email }.to("new1+2@example.com")
        .and change { product3.reload.support_email }.to("new3@example.com")
    end

    it "raises an error if any of the emails is invalid" do
      entries = [
        { email: "new1@example.com", product_ids: [product1.external_id] },
        { email: "invalid", product_ids: [product2.external_id] }
      ]

      service = described_class.new(user, entries)

      expect { service.perform }
        .to raise_error(ActiveModel::ValidationError)
        .with_message("Validation failed: Support email is invalid")

      expect(product1.reload.support_email).to eq("old1@example.com")
      expect(product2.reload.support_email).to eq("old2@example.com")
      expect(product3.reload.support_email).to eq("old3@example.com")
    end

    it "clears support emails for products not in any entry" do
      entries = [{ email: "new1@example.com", product_ids: [product1.external_id] }]

      service = described_class.new(user, entries)

      expect { service.perform }
        .to change { product1.reload.support_email }.to("new1@example.com")
        .and change { product2.reload.support_email }.to(nil)
        .and change { product3.reload.support_email }.to(nil)
    end

    it "clears all support emails when provided empty array" do
      service = described_class.new(user, [])

      expect { service.perform }
        .to change { product1.reload.support_email }.to(nil)
        .and change { product2.reload.support_email }.to(nil)
        .and change { product3.reload.support_email }.to(nil)
    end

    it "clears all support emails when provided nil" do
      service = described_class.new(user, nil)

      expect { service.perform }
        .to change { product1.reload.support_email }.to(nil)
        .and change { product2.reload.support_email }.to(nil)
        .and change { product3.reload.support_email }.to(nil)
    end

    it "does not update products that do not belong to the user" do
      entries = [
        { email: "new1@example.com", product_ids: [product1.external_id] },
        { email: "new2@example.com", product_ids: [other_user_product.external_id] }
      ]

      service = described_class.new(user, entries)

      expect { service.perform }
        .to change { product1.reload.support_email }.to("new1@example.com")
        .and not_change { other_user_product.reload.support_email }
    end

    context "when user does not have product_level_support_emails enabled" do
      before do
        Feature.deactivate_user(:product_level_support_emails, user)
      end

      it "does not update any product support emails" do
        entries = [{ email: "new@example.com", product_ids: [product1.external_id] }]
        service = described_class.new(user, entries)
        service.perform

        expect(product1.reload.support_email).to eq("old1@example.com")
        expect(product2.reload.support_email).to eq("old2@example.com")
        expect(product3.reload.support_email).to eq("old3@example.com")
      end
    end
  end
end
