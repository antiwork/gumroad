# frozen_string_literal: true

require "spec_helper"

describe ReceiptPresenter::FooterInfo, :vcr do
  include ActionView::Helpers::UrlHelper

  let(:product) { create(:membership_product) }
  let(:purchase) { create(:membership_purchase, email: "customer@example.com", link: product, price_cents: 1_000) }

  let(:for_email) { true }
  let(:presenter) { described_class.new(chargeable) }

  describe "#can_manage_subscription?" do
    context "when product is a recurring billing" do
      context "when chargeable is a Purchase" do
        let(:chargeable) { purchase }

        it "returns true" do
          expect(presenter.can_manage_subscription?).to be(true)
        end

        context "when is a receipt for gift receiver" do
          let(:gift) { create(:gift, link: product) }

          before do
            purchase.update!(gift_received: gift, is_gift_receiver_purchase: true)
          end

          it "returns false" do
            expect(presenter.can_manage_subscription?).to be(false)
          end
        end

        context "when the purchase has no subscription" do
          before { purchase.update!(subscription: nil) }

          it "returns false" do
            expect(presenter.can_manage_subscription?).to be(false)
          end
        end

        context "when is a receipt for gift sender" do
          let(:gift) { create(:gift, link: product) }

          before do
            purchase.update!(gift_given: gift, is_gift_sender_purchase: true)
          end

          it "returns false" do
            expect(presenter.can_manage_subscription?).to be(false)
          end
        end
      end

      context "when chargeable is a Charge" do
        let(:chargeable) { create(:charge, purchases: [purchase]) }

        it "returns false" do
          expect(presenter.can_manage_subscription?).to be(false)
        end
      end
    end
  end

  describe "#manage_subscription_note" do
    let(:chargeable) { purchase }

    it "returns expected text" do
      expect(presenter.manage_subscription_note).to eq("You'll be charged once a month.")
    end

    context "when the membership only ever charges once" do
      before do
        purchase.subscription.update!(charge_occurrence_count: 1)
      end

      it "returns one-time wording instead of a recurring charge promise" do
        expect(presenter.manage_subscription_note).to eq("You won't be charged again for this membership.")
      end
    end

    context "when a free trial membership only ever charges once" do
      let(:purchase) { create(:free_trial_membership_purchase, email: "customer@example.com") }

      before do
        purchase.subscription.update!(charge_occurrence_count: 1)
      end

      it "keeps the recurring wording because the single charge hasn't happened yet" do
        expect(presenter.manage_subscription_note).to eq("You'll be charged once a month.")
      end
    end
  end

  describe "#manage_subscription_link" do
    let(:chargeable) { purchase }
    let(:expected_url) do
      Rails.application.routes.url_helpers.manage_subscription_url(
        purchase.subscription.external_id,
        host: UrlService.domain_with_protocol,
      )
    end

    it "returns the expected link" do
      expect(presenter.manage_subscription_link).to include("Manage membership")
      expect(presenter.manage_subscription_link).to include(expected_url)
    end
  end

  describe "#unsubscribe_link" do
    let(:chargeable) { purchase }

    it "returns the expected link" do
      allow_any_instance_of(Purchase).to receive(:secure_external_id).and_return("sample-secure-id")
      expected_url = Rails.application.routes.url_helpers.unsubscribe_purchase_url(
        "sample-secure-id",
        host: UrlService.domain_with_protocol,
      )

      expect(presenter.unsubscribe_link).to include("Unsubscribe")
      expect(presenter.unsubscribe_link).to include(expected_url)
    end
  end

  describe "#show_refund_request_link? and #refund_request_link" do
    let(:chargeable) { create(:purchase) }

    context "when the buyer_refund_requests flag is off" do
      it "does not show the link" do
        expect(presenter.show_refund_request_link?).to be(false)
      end
    end

    context "when the buyer_refund_requests flag is on for the seller" do
      before { Feature.activate_user(:buyer_refund_requests, chargeable.seller) }

      it "shows the link for an eligible purchase" do
        expect(presenter.show_refund_request_link?).to be(true)
      end

      it "does not show the link for a refunded purchase" do
        chargeable.update!(stripe_refunded: true)
        expect(presenter.show_refund_request_link?).to be(false)
      end

      it "shows the link for a checkout Charge receipt with one purchase, signed for that purchase" do
        charge_presenter = described_class.new(create(:charge, seller: chargeable.seller, purchases: [chargeable]))
        token_purchase = nil
        allow_any_instance_of(Purchase).to receive(:secure_external_id) { |purchase, **| token_purchase = purchase; "sample-secure-id" }

        expect(charge_presenter.show_refund_request_link?).to be(true)
        expect(charge_presenter.refund_request_link).to include("sample-secure-id")
        expect(token_purchase).to eq(chargeable)
      end

      it "does not show the link for a Charge receipt with several purchases" do
        other_purchase = create(:purchase, link: create(:product, user: chargeable.seller), seller: chargeable.seller)
        charge_presenter = described_class.new(create(:charge, seller: chargeable.seller, purchases: [chargeable, other_purchase]))

        expect(charge_presenter.show_refund_request_link?).to be(false)
      end

      it "links to the signed refund request page" do
        allow_any_instance_of(Purchase).to receive(:secure_external_id).and_return("sample-secure-id")
        expected_url = Rails.application.routes.url_helpers.purchase_refund_request_url(
          "sample-secure-id",
          host: UrlService.domain_with_protocol,
        )

        expect(presenter.refund_request_link).to include("Request a refund")
        expect(presenter.refund_request_link).to include(expected_url)
      end
    end
  end
end
