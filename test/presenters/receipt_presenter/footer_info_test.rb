# frozen_string_literal: true

require "test_helper"

class ReceiptPresenterFooterInfoTest < ActiveSupport::TestCase
  self.described_class = ReceiptPresenter::FooterInfo
  self.rspec_metadata = { vcr: true }



  context_ ReceiptPresenter::FooterInfo, :vcr do
    include ActionView::Helpers::UrlHelper

    let(:product) { create(:membership_product) }
    let(:purchase) { create(:membership_purchase, email: "customer@example.com", link: product) }

    let(:for_email) { true }
    let(:presenter) { described_class.new(chargeable) }

  context_ "#can_manage_subscription?" do
  context_ "when product is a recurring billing" do
  context_ "when chargeable is a Purchase" do
          let(:chargeable) { purchase }

  test "returns true" do
            expect(presenter.can_manage_subscription?).to be(true)
          end

  context_ "when is a receipt for gift receiver" do
            let(:gift) { create(:gift, link: product) }

            before do
              purchase.update!(gift_received: gift, is_gift_receiver_purchase: true)
            end

  test "returns false" do
              expect(presenter.can_manage_subscription?).to be(false)
            end
          end

  context_ "when is a receipt for gift sender" do
            let(:gift) { create(:gift, link: product) }

            before do
              purchase.update!(gift_given: gift, is_gift_sender_purchase: true)
            end

  test "returns false" do
              expect(presenter.can_manage_subscription?).to be(false)
            end
          end
        end

  context_ "when chargeable is a Charge" do
          let(:chargeable) { create(:charge, purchases: [purchase]) }

  test "returns false" do
            expect(presenter.can_manage_subscription?).to be(false)
          end
        end
      end
    end

  context_ "#manage_subscription_note" do
      let(:chargeable) { purchase }

  test "returns expected text" do
        expect(presenter.manage_subscription_note).to eq("You'll be charged once a month.")
      end
    end

  context_ "#manage_subscription_link" do
      let(:chargeable) { purchase }
      let(:expected_url) do
        Rails.application.routes.url_helpers.manage_subscription_url(
          purchase.subscription.external_id,
          host: UrlService.domain_with_protocol,
        )
      end

  test "returns the expected link" do
        expect(presenter.manage_subscription_link).to include("Manage membership")
        expect(presenter.manage_subscription_link).to include(expected_url)
      end
    end

  context_ "#unsubscribe_link" do
      let(:chargeable) { purchase }

  test "returns the expected link" do
        allow_any_instance_of(Purchase).to receive(:secure_external_id).and_return("sample-secure-id")
        expected_url = Rails.application.routes.url_helpers.unsubscribe_purchase_url(
          "sample-secure-id",
          host: UrlService.domain_with_protocol,
        )

        expect(presenter.unsubscribe_link).to include("Unsubscribe")
        expect(presenter.unsubscribe_link).to include(expected_url)
      end
    end
  end
end
