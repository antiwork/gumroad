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

      it "checks a shared unmatched original purchase once for multiple recurring charges" do
        subscription = create(:subscription, user: buyer)
        original_purchase = create(:purchase, email: "old_original@example.com", purchaser: buyer, is_original_subscription_purchase: true, subscription:, merchant_account:)
        create(:purchase, email: from_email, purchaser: buyer, subscription:, merchant_account:)
        create(:purchase, email: from_email, purchaser: buyer, subscription:, merchant_account:)

        service = described_class.new(from_email:, to_email:)
        allow(service).to receive(:payment_fingerprint).and_call_original

        service.perform

        expect(service).to have_received(:payment_fingerprint).with(original_purchase).once
      end

      it "preloads subscriptions and original purchases before the guard checks recurring charges" do
        subscription = create(:subscription, user: buyer)
        original_purchase = create(:purchase, email: "old_original@example.com", purchaser: buyer, is_original_subscription_purchase: true, subscription:, merchant_account:, is_reassignment_locked: true)
        3.times { create(:purchase, email: from_email, purchaser: buyer, subscription:, merchant_account:) }

        subscription_selects = []
        original_purchase_selects = []
        counter = lambda do |_name, _started, _finished, _unique_id, payload|
          sql = payload[:sql]
          next unless sql.start_with?("SELECT")

          subscription_selects << sql if sql.match?(/FROM [`"]subscriptions[`"]/)
          original_purchase_selects << sql if sql.match?(/FROM [`"]purchases[`"]/) && sql.match?(/[`"]purchases[`"]\.[`"]subscription_id[`"]/)
        end

        result = nil
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
          result = described_class.new(from_email:, to_email:).perform
        end

        expect(result.reason).to eq(:locked)
        expect(original_purchase.reload.email).to eq("old_original@example.com")
        expect(subscription_selects.size).to eq(1)
        expect(original_purchase_selects.size).to eq(1)
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

    context "when a matched purchase is reassignment-locked" do
      let!(:target_user) { create(:user, email: to_email) }
      let!(:unlocked_purchase) { create(:purchase, email: from_email, purchaser: buyer, merchant_account:) }
      let!(:locked_purchase) { create(:purchase, email: from_email, purchaser: buyer, merchant_account:, is_reassignment_locked: true) }

      it "refuses the whole batch without mutating any purchase" do
        expect(CustomerMailer).not_to receive(:grouped_receipt)

        result = described_class.new(from_email:, to_email:).perform

        expect(result.success?).to be(false)
        expect(result.reason).to eq(:locked)
        expect(result.error_message).to eq("One or more purchases are under review and cannot be reassigned")
        expect(result.reassigned_purchase_ids).to eq([])
        expect(unlocked_purchase.reload.email).to eq(from_email)
        expect(locked_purchase.reload.email).to eq(from_email)
      end
    end

    context "when purchases span too many distinct cards" do
      let!(:target_user) { create(:user, email: to_email) }

      before do
        ["**** **** **** 1111", "**** **** **** 2222", "**** **** **** 3333", "**** **** **** 4444"].each do |card_visual|
          purchase = create(:purchase, email: from_email, purchaser: buyer, merchant_account:)
          purchase.update_column(:card_visual, card_visual)
        end
      end

      it "refuses with reason :fingerprint_anomaly and does not mutate purchases" do
        expect(CustomerMailer).not_to receive(:grouped_receipt)

        result = described_class.new(from_email:, to_email:).perform

        expect(result.success?).to be(false)
        expect(result.reason).to eq(:fingerprint_anomaly)
        expect(result.error_message).to eq("This reassignment spans an unusual number of distinct payment methods and requires manual review")
        expect(result.reassigned_purchase_ids).to eq([])
        expect(Purchase.where(email: from_email).count).to eq(4)
      end

      it "allows the high-card-diversity move when confirmed_override is true" do
        result = described_class.new(from_email:, to_email:, confirmed_override: true).perform

        expect(result.success?).to be(true)
        expect(result.count).to eq(4)
        expect(Purchase.where(email: from_email).count).to eq(0)
      end
    end

    context "when purchases use a normal one-to-two card library" do
      let!(:target_user) { create(:user, email: to_email) }

      before do
        ["**** **** **** 1111", "**** **** **** 1111", "**** **** **** 2222"].each do |card_visual|
          purchase = create(:purchase, email: from_email, purchaser: buyer, merchant_account:)
          purchase.update_column(:card_visual, card_visual)
        end
      end

      it "does not trip the fingerprint guard" do
        result = described_class.new(from_email:, to_email:).perform

        expect(result.success?).to be(true)
        expect(result.count).to eq(3)
      end
    end

    context "when purchases span too many distinct non-card payment methods" do
      let!(:target_user) { create(:user, email: to_email) }

      before do
        ["paypal-a@example.com", "paypal-b@example.com", "paypal-c@example.com", "paypal-d@example.com"].each do |visual|
          purchase = create(:purchase, email: from_email, purchaser: buyer, merchant_account:)
          purchase.update_column(:card_visual, visual)
        end
      end

      it "refuses with reason :fingerprint_anomaly for distinct non-card visuals" do
        result = described_class.new(from_email:, to_email:).perform

        expect(result.success?).to be(false)
        expect(result.reason).to eq(:fingerprint_anomaly)
      end
    end

    context "when purchases span distinct non-card visuals containing digits" do
      let!(:target_user) { create(:user, email: to_email) }

      before do
        ["buyer2024-a@example.com", "buyer2024-b@example.com", "buyer2024-c@example.com", "buyer2024-d@example.com"].each do |visual|
          purchase = create(:purchase, email: from_email, purchaser: buyer, merchant_account:)
          purchase.update_column(:card_visual, visual)
        end
      end

      it "does not collapse numeric PayPal emails into a single card fingerprint" do
        result = described_class.new(from_email:, to_email:).perform

        expect(result.success?).to be(false)
        expect(result.reason).to eq(:fingerprint_anomaly)
      end
    end

    context "when non-card payment visuals contain a card-like line" do
      let!(:target_user) { create(:user, email: to_email) }

      before do
        ["paypal-a@example.com", "paypal-b@example.com", "paypal-c@example.com", "paypal-d@example.com"].each do |visual|
          purchase = create(:purchase, email: from_email, purchaser: buyer, merchant_account:)
          purchase.update_column(:card_visual, "#{visual}\n**** **** **** 1234")
        end
      end

      it "does not collapse the multi-line visuals into the same card fingerprint" do
        result = described_class.new(from_email:, to_email:).perform

        expect(result.success?).to be(false)
        expect(result.reason).to eq(:fingerprint_anomaly)
      end
    end

    context "when a locked original subscription purchase is not in the matched set" do
      let!(:target_user) { create(:user, email: to_email) }

      it "refuses the batch because a mutable purchase is locked" do
        subscription = create(:subscription, user: buyer)
        original_purchase = create(:purchase, email: "old_original@example.com", purchaser: buyer, is_original_subscription_purchase: true, subscription:, merchant_account:, is_reassignment_locked: true)
        recurring = create(:purchase, email: from_email, purchaser: buyer, subscription:, merchant_account:)

        result = described_class.new(from_email:, to_email:).perform

        expect(result.success?).to be(false)
        expect(result.reason).to eq(:locked)
        expect(recurring.reload.email).to eq(from_email)
        expect(original_purchase.reload.email).to eq("old_original@example.com")
      end
    end
  end
end
