# frozen_string_literal: true

require "spec_helper"

describe ReceiptPresenter::GifteeManageSubscription do
  let(:chargeable) { create(:membership_purchase, gift_received: create(:gift), is_gift_receiver_purchase: true) }
  let(:subscription) { chargeable.subscription }
  let(:presenter) { described_class.new(chargeable) }

  describe "#note" do
    let(:expected_url) do
      Rails.application.routes.url_helpers.manage_subscription_url(
        subscription.external_id,
        host: UrlService.domain_with_protocol,
      )
    end

    context "when the chargeable is not a purchase" do
      let(:chargeable) { create(:charge) }

      it "returns nil" do
        expect(presenter.note).to be_nil
      end
    end

    context "when the subscription is not a gift" do
      before do
        chargeable.update!(is_gift_receiver_purchase: false)
      end

      it "returns nil" do
        expect(presenter.note).to be_nil
      end
    end

    context "when the chargeable is a subscription and gift" do
      before do
        chargeable.update!(is_gift_receiver_purchase: true)
        create(:membership_purchase, gift_given: chargeable.gift_received, is_gift_sender_purchase: true, subscription:)
      end

      it "returns the expected note" do
        expect(presenter.note).to eq(
          "Your gift includes a 1-month membership. If you wish to continue your membership, you can visit <a target=\"_blank\" href=\"#{expected_url}\">subscription settings</a>."
        )
      end
    end
  end
end
