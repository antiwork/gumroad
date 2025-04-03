# frozen_string_literal: true

require "spec_helper"

describe Onetime::NotifySellersWithRefundPolicies do
  let(:seller_one) { create(:user) }
  let(:seller_two) { create(:user) }
  let(:product_one) { create(:product, user: seller_one) }
  let(:product_two) { create(:product, user: seller_two) }
  let!(:product_refund_policy_one) { create(:product_refund_policy, product: product_one) }
  let!(:product_refund_policy_two) { create(:product_refund_policy, product: product_two) }

  describe ".reset_last_processed_seller_id" do
    it "deletes the redis key" do
      $redis.set(described_class::LAST_PROCESSED_ID_KEY, 123)
      described_class.reset_last_processed_seller_id
      expect($redis.get(described_class::LAST_PROCESSED_ID_KEY)).to be_nil
    end
  end

  describe "#process" do
    subject(:process) { described_class.new(max_id: product_refund_policy_two.id).process }

    it "sends emails to all eligible sellers" do
      expect do
        process
      end.to have_enqueued_mail(ContactingCreatorMailer, :upcoming_refund_policy_change).with(seller_one.id)
        .and have_enqueued_mail(ContactingCreatorMailer, :upcoming_refund_policy_change).with(seller_two.id)
    end

    it "marks all eligible sellers as notified" do
      expect do
        process
      end.to change { seller_one.reload.upcoming_refund_policy_change_email_sent? }.from(false).to(true)
        .and change { seller_two.reload.upcoming_refund_policy_change_email_sent? }.from(false).to(true)
    end

    it "updates the last processed id in redis" do
      process
      expect($redis.get(described_class::LAST_PROCESSED_ID_KEY).to_i).to eq(product_refund_policy_two.id)
    end

    context "when one seller was already notified" do
      before do
        seller_one.update!(upcoming_refund_policy_change_email_sent: true)
      end

      it "only sends email to non-notified seller" do
        expect do
          process
        end.to have_enqueued_mail(ContactingCreatorMailer, :upcoming_refund_policy_change).with(seller_two.id)
          .exactly(:once)
      end

      it "does not update already notified seller" do
        expect do
          process
        end.to not_change { seller_one.reload.upcoming_refund_policy_change_email_sent? }
          .and change { seller_two.reload.upcoming_refund_policy_change_email_sent? }.from(false).to(true)
      end
    end

    context "when product_refund_policy has no product" do
      before do
        product_refund_policy_one.update_column(:product_id, nil)
      end

      it "only processes seller with valid product" do
        expect do
          process
        end.to have_enqueued_mail(ContactingCreatorMailer, :upcoming_refund_policy_change).with(seller_two.id)
          .exactly(:once)
      end

      it "only updates seller with valid product" do
        expect do
          process
        end.to not_change { seller_one.reload.upcoming_refund_policy_change_email_sent? }
          .and change { seller_two.reload.upcoming_refund_policy_change_email_sent? }.from(false).to(true)
      end
    end

    context "when there's a last processed id in redis" do
      before do
        $redis.set(described_class::LAST_PROCESSED_ID_KEY, product_refund_policy_one.id)
      end

      it "only processes records after the last processed id" do
        expect do
          process
        end.to have_enqueued_mail(ContactingCreatorMailer, :upcoming_refund_policy_change).with(seller_two.id)
          .exactly(:once)
      end

      it "only updates sellers after the last processed id" do
        expect do
          process
        end.to not_change { seller_one.reload.upcoming_refund_policy_change_email_sent? }
          .and change { seller_two.reload.upcoming_refund_policy_change_email_sent? }.from(false).to(true)
      end
    end
  end
end
