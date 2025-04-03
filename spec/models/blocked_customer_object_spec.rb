# frozen_string_literal: true

require "spec_helper"

describe BlockedCustomerObject do
  describe "validations" do
    subject(:blocked_customer_object) { build(:blocked_customer_object, object_type: nil, object_value: nil) }

    describe "presence" do
      it "doesn't allow an empty seller_id" do
        blocked_customer_object.seller = nil

        expect(blocked_customer_object).to be_invalid
        expect(blocked_customer_object.errors.full_messages).to include("Seller must exist")
      end

      it "doesn't allow an empty object_type" do
        expect(blocked_customer_object).to be_invalid
        expect(blocked_customer_object.errors.full_messages).to include("Object type can't be blank")
      end

      it "doesn't allow an empty object_value" do
        expect(blocked_customer_object).to be_invalid
        expect(blocked_customer_object.errors.full_messages).to include("Object value can't be blank")
      end
    end

    describe "inclusion" do
      it "doesn't allow an unsupported object_type" do
        blocked_customer_object.object_type = "something"

        expect(blocked_customer_object).to be_invalid
        expect(blocked_customer_object.errors.full_messages).to include("Object type is not included in the list")
      end
    end

    describe "format" do
      it "doesn't allow an object_value with an invalid email if object_type is 'email'" do
        blocked_customer_object.object_type = "email"
        blocked_customer_object.object_value = "invalid-email"

        expect(blocked_customer_object).to be_invalid
        expect(blocked_customer_object.errors.full_messages).to include("Object value is invalid")
      end
    end
  end

  describe "scopes" do
    let(:seller) { create(:named_seller) }
    let!(:blocked_email1) { create(:blocked_customer_object, seller:, object_type: "email", object_value: "john@example.com", blocked_at: DateTime.current) }
    let!(:blocked_email2) { create(:blocked_customer_object, seller:, object_type: "email", object_value: "alice@example.com") }

    describe ".email" do
      it "returns records matching object_type 'email'" do
        expect(described_class.email.count).to eq(2)
        expect(described_class.email).to match_array([blocked_email1, blocked_email2])
      end
    end

    describe ".active" do
      it "returns records having non-nil blocked_at" do
        expect(described_class.active.count).to eq(1)
        expect(described_class.active).to match_array([blocked_email1])
      end
    end

    describe ".inactive" do
      it "returns records having nil blocked_at" do
        expect(described_class.inactive.count).to eq(1)
        expect(described_class.inactive).to match_array([blocked_email2])
      end
    end
  end

  describe ".email_blocked?" do
    let(:seller) { create(:named_seller) }

    context "when the given email is blocked by the seller" do
      before do
        BlockedCustomerObject.block_email!(email: "customer@example.com", seller_id: seller.id)
      end

      it "returns true" do
        expect(described_class.email_blocked?(email: "cuST.omer+test1234@example.com", seller_id: seller.id)).to be(true)
      end
    end

    context "when the given email is not blocked by the seller" do
      let(:another_seller) { create(:user) }

      before do
        BlockedCustomerObject.block_email!(email: "customer@example.com", seller_id: another_seller.id)
        BlockedCustomerObject.block_email!(email: "another-customer@example.com", seller_id: seller.id)
        BlockedCustomerObject.block_email!(email: "customer@example.com", seller_id: seller.id)

        seller.blocked_customer_objects.active.email.find_by(object_value: "customer@example.com").unblock!
      end

      it "returns false" do
        expect(described_class.email_blocked?(email: "customer@example.com", seller_id: seller.id)).to be(false)
      end
    end
  end

  describe ".block_email!" do
    let(:seller) { create(:named_seller) }

    context "when the email is not blocked or unblocked" do
      it "blocks the email" do
        expect(seller.blocked_customer_objects.active.email.count).to eq(0)

        expect do
          described_class.block_email!(email: "john@example.com", seller_id: seller.id)
        end.to change(described_class, :count).by(1)

        expect(seller.blocked_customer_objects.active.email.pluck(:object_value)).to match_array(["john@example.com"])
      end
    end

    context "when the email is already blocked" do
      let!(:blocked_email_object) { create(:blocked_customer_object, seller:, object_type: "email", object_value: "john@example.com", blocked_at: 5.minutes.ago) }

      it "does nothing" do
        expect do
          described_class.block_email!(email: "john@example.com", seller_id: seller.id)
        end.not_to change(described_class, :count)

        expect(seller.blocked_customer_objects.active.email).to match_array([blocked_email_object])
      end
    end

    context "when the email is unblocked" do
      let!(:blocked_email_object) { create(:blocked_customer_object, seller:, object_type: "email", object_value: "john@example.com") }

      it "blocks the email" do
        freeze_time do
          expect do
            expect do
              described_class.block_email!(email: "john@example.com", seller_id: seller.id)
            end.not_to change(described_class, :count)
          end.to change { blocked_email_object.reload.blocked_at }.from(nil).to(DateTime.current)
        end
      end
    end
  end

  describe "#unblock!" do
    let(:seller) { create(:named_seller) }
    let!(:blocked_object) { create(:blocked_customer_object, seller:, object_type: "email", object_value: "john@example.com", blocked_at: DateTime.parse("January 1, 2023")) }

    it "unblocks the object" do
      expect do
        blocked_object.unblock!
      end.to change { blocked_object.reload.blocked_at }.from(DateTime.parse("January 1, 2023")).to(nil)
    end

    it "does nothing if the object is already unblocked" do
      blocked_object.update!(blocked_at: nil)

      expect do
        blocked_object.reload.unblock!
      end.not_to change { blocked_object.reload.blocked_at }

      expect(blocked_object.blocked_at).to be_nil
    end
  end
end
