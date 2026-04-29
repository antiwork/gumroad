# frozen_string_literal: true

require "spec_helper"

describe Purchase::ReassignByEmailService do
  let(:from_email) { "old@example.com" }
  let(:to_email) { "new@example.com" }
  let(:buyer) { create(:user) }
  let(:merchant_account) { create(:merchant_account, user: nil) }

  describe "#perform" do
    context "when both emails are missing or blank" do
      it "returns reason :missing_params when from_email is blank" do
        result = described_class.new(from_email: "", to_email:).perform

        expect(result.success?).to be(false)
        expect(result.reason).to eq(:missing_params)
        expect(result.error_message).to eq("Both 'from' and 'to' email addresses are required")
        expect(result.reassigned_purchase_ids).to eq([])
      end

      it "returns reason :missing_params when to_email is blank" do
        result = described_class.new(from_email:, to_email: nil).perform

        expect(result.success?).to be(false)
        expect(result.reason).to eq(:missing_params)
        expect(result.error_message).to eq("Both 'from' and 'to' email addresses are required")
      end
    end

    context "when no purchases match from_email" do
      it "returns reason :not_found" do
        result = described_class.new(from_email: "nobody@example.com", to_email:).perform

        expect(result.success?).to be(false)
        expect(result.reason).to eq(:not_found)
        expect(result.error_message).to eq("No purchases found for email: nobody@example.com")
        expect(result.reassigned_purchase_ids).to eq([])
      end
    end

    context "when from_email and to_email match" do
      it "returns reason :no_changes for an exact match" do
        result = described_class.new(from_email: "user@example.com", to_email: "user@example.com").perform

        expect(result.success?).to be(false)
        expect(result.reason).to eq(:no_changes)
        expect(result.error_message).to eq("from and to emails are the same")
        expect(result.reassigned_purchase_ids).to eq([])
      end

      it "rejects same email case-insensitively" do
        result = described_class.new(from_email: "User@Example.com", to_email: "user@example.com").perform

        expect(result.success?).to be(false)
        expect(result.reason).to eq(:no_changes)
      end

      it "does not query Purchase or enqueue a receipt when same emails are submitted" do
        expect(Purchase).not_to receive(:where)
        expect(CustomerMailer).not_to receive(:grouped_receipt)

        described_class.new(from_email: "user@example.com", to_email: "user@example.com").perform
      end
    end

    context "when target user exists" do
      let!(:target_user) { create(:user, email: to_email) }
      let!(:purchase1) { create(:purchase, email: from_email, purchaser: buyer, merchant_account:) }
      let!(:purchase2) { create(:purchase, email: from_email, purchaser: buyer, merchant_account:) }

      it "reassigns email and purchaser_id to the target user" do
        result = described_class.new(from_email:, to_email:).perform

        expect(result.success?).to be(true)
        expect(result.count).to eq(2)
        expect(purchase1.reload.email).to eq(to_email)
        expect(purchase1.purchaser_id).to eq(target_user.id)
        expect(purchase2.reload.email).to eq(to_email)
        expect(purchase2.purchaser_id).to eq(target_user.id)
      end

      it "transfers subscription ownership to the target user for original subscription purchases" do
        subscription = create(:subscription, user: buyer)
        sub_purchase = create(:purchase, email: from_email, purchaser: buyer, is_original_subscription_purchase: true, subscription:, merchant_account:)

        described_class.new(from_email:, to_email:).perform

        expect(sub_purchase.reload.email).to eq(to_email)
        expect(subscription.reload.user).to eq(target_user)
      end

      it "does not modify subscription.user when the original-subscription purchase save fails" do
        subscription = create(:subscription, user: buyer)
        sub_purchase = create(:purchase, email: from_email, purchaser: buyer, is_original_subscription_purchase: true, subscription:, merchant_account:)

        allow_any_instance_of(Purchase).to receive(:save).and_return(false)

        described_class.new(from_email:, to_email:).perform

        expect(subscription.reload.user).to eq(buyer)
        expect(sub_purchase.reload.email).to eq(from_email)
      end

      it "transfers full ownership of an original_purchase that is not in the matched set" do
        subscription = create(:subscription, user: buyer)
        original_purchase = create(:purchase, email: "old_original@example.com", purchaser: buyer, is_original_subscription_purchase: true, subscription:, merchant_account:)
        recurring = create(:purchase, email: from_email, purchaser: buyer, subscription:, merchant_account:)

        described_class.new(from_email:, to_email:).perform

        expect(original_purchase.reload.email).to eq(to_email)
        expect(original_purchase.purchaser_id).to eq(target_user.id)
        expect(recurring.reload.email).to eq(to_email)
        expect(recurring.purchaser_id).to eq(target_user.id)
        expect(subscription.reload.user).to eq(target_user)
      end

      it "does not modify subscription.user when the original_purchase update fails" do
        subscription = create(:subscription, user: buyer)
        original_purchase = create(:purchase, email: "old_original@example.com", purchaser: buyer, is_original_subscription_purchase: true, subscription:, merchant_account:)
        create(:purchase, email: from_email, purchaser: buyer, subscription:, merchant_account:)

        allow_any_instance_of(Purchase).to receive(:update).with(hash_including(:email)).and_return(false)

        described_class.new(from_email:, to_email:).perform

        expect(subscription.reload.user).to eq(buyer)
        expect(original_purchase.reload.email).to eq("old_original@example.com")
      end

      it "enqueues a grouped receipt for all reassigned purchases" do
        expect(CustomerMailer).to receive(:grouped_receipt).with(match_array([purchase1.id, purchase2.id])).and_call_original

        described_class.new(from_email:, to_email:).perform
      end
    end

    context "when no purchases save successfully" do
      let!(:target_user) { create(:user, email: to_email) }
      let!(:purchase) { create(:purchase, email: from_email, purchaser: buyer, merchant_account:) }

      it "returns reason :no_changes and does not enqueue a grouped receipt" do
        allow_any_instance_of(Purchase).to receive(:save).and_return(false)
        expect(CustomerMailer).not_to receive(:grouped_receipt)

        result = described_class.new(from_email:, to_email:).perform

        expect(result.success?).to be(false)
        expect(result.reason).to eq(:no_changes)
        expect(result.error_message).to eq("No purchases were reassigned")
        expect(result.reassigned_purchase_ids).to eq([])
      end
    end

    context "when target user does not exist" do
      let!(:purchase) { create(:purchase, email: from_email, purchaser: buyer, merchant_account:) }

      it "still reassigns the email but sets purchaser_id to nil" do
        result = described_class.new(from_email:, to_email: "nobody-new@example.com").perform

        expect(result.success?).to be(true)
        expect(purchase.reload.email).to eq("nobody-new@example.com")
        expect(purchase.purchaser_id).to be_nil
      end

      it "clears the subscription user for original subscription purchases" do
        subscription = create(:subscription, user: buyer)
        sub_purchase = create(:purchase, email: from_email, purchaser: buyer, is_original_subscription_purchase: true, subscription:, merchant_account:)

        described_class.new(from_email:, to_email: "nobody-new@example.com").perform

        expect(sub_purchase.reload.purchaser_id).to be_nil
        expect(subscription.reload.user).to be_nil
      end
    end

    context "when the to_email belongs only to a soft-deleted user" do
      let!(:deleted_user) { create(:user, email: to_email).tap(&:deactivate!) }
      let!(:purchase) { create(:purchase, email: from_email, purchaser: buyer, merchant_account:) }

      it "treats the email as having no target user and reassigns with purchaser_id nil" do
        result = described_class.new(from_email:, to_email:).perform

        expect(result.success?).to be(true)
        expect(purchase.reload.email).to eq(to_email)
        expect(purchase.purchaser_id).to be_nil
      end
    end
  end
end
