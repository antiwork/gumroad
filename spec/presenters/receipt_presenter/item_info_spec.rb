# frozen_string_literal: true

require "spec_helper"
require "shared_examples/receipt_presenter_concern"

describe ReceiptPresenter::ItemInfo do
  include ActionView::Helpers::UrlHelper

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) do
    create(
      :purchase,
      link: product,
      seller:,
      price_cents: 1_499,
      created_at: DateTime.parse("January 1, 2023")
    )
  end
  let(:item_info) { described_class.new(purchase) }

  describe ".new" do
    let(:subscription) { create(:subscription) }

    it "assigns instance variables" do
      expect(item_info.send(:product)).to eq(product)
      expect(item_info.send(:purchase)).to eq(purchase)
      expect(item_info.send(:seller)).to eq(purchase.seller)
      expect(item_info.send(:subscription)).to eq(purchase.subscription)
    end
  end

  describe "#props" do
    let(:props) { item_info.props }

    it "returns a hash with the correct keys" do
      expect(props.keys).to eq(
        %i[
          notes custom_receipt_note show_download_button license_key gift_attributes
          general_attributes product manage_subscription_note
        ]
      )
    end

    describe "notes" do
      context "when the purchase is a free trial" do
        let(:purchase) { create(:free_trial_membership_purchase) }

        it "returns note" do
          expect(props[:notes]).to eq(["Your free trial has begun!"])
        end
      end

      context "when the purchase is for a physical product" do
        include_context "when the purchase is for a physical product"

        it "returns physical_product_note" do
          expect(props[:notes]).to eq(["Your order will ship shortly. The creator will notify you when your package is on its way."])
        end

        context "when is a gift sender purchase" do
          include_context "when is a gift sender purchase"

          it "returns an empty array" do
            expect(props[:notes]).to eq([])
          end
        end

        context "if is preorder authorization" do
          include_context "when is a preorder authorization"

          it "returns notes" do
            expect(props[:notes]).to eq(
              [
                "The shipment will occur soon after December 1st, 10AM PST.",
                "You'll get it on December 1st, 10AM PST."
              ]
            )
          end
        end
      end

      context "when the purchase is a rental" do
        before do
          purchase.update!(is_rental: true)
        end

        it "return rental note" do
          expect(props[:notes]).to eq(["Your rental of The Works of Edgar Gumstein will expire in 30 days or 72 hours after you begin viewing it."])
        end
      end

      it "returns an empty array" do
        expect(props[:notes]).to eq([])
      end
    end

    describe "custom_receipt_note" do
      context "when the product does not have a custom receipt note" do
        it "returns nil" do
          expect(props[:custom_receipt_note]).to be_nil
        end
      end

      context "when the product has a custom receipt note" do
        before do
          purchase.link.update!(custom_receipt: "Here is a link to https://example.com")
        end

        it "returns formatted custom receipt note" do
          expect(props[:custom_receipt_note]).to eq("<p>Here is a link to <a href=\"https://example.com\">https://example.com</a></p>")
        end

        context "when the purchase has a gift note" do
          let(:gift) { create(:gift, gift_note: "Gift note") }
          let!(:gifter_purchase) { create(:purchase, link: gift.link, gift_given: gift, is_gift_sender_purchase: true) }
          let(:purchase) { create(:purchase, link: gift.link, gift_received: gift, is_gift_receiver_purchase: true) }

          it "returns nil" do
            expect(props[:custom_receipt_note]).to be_nil
          end
        end
      end
    end

    describe "show_download_button" do
      context "when the purchase has url_redirect" do
        before do
          purchase.create_url_redirect!
        end

        context "when the product has content for url redirects" do
          it "returns true" do
            expect(props[:show_download_button]).to eq(true)
          end

          context "when is gift sender purchase" do
            include_context "when is a gift sender purchase"

            it "returns false" do
              expect(props[:show_download_button]).to eq(false)
            end
          end

          context "when is a preorder authorization" do
            include_context "when is a preorder authorization"

            it "returns false" do
              expect(props[:show_download_button]).to eq(false)
            end
          end

          context "when is a coffee purchase" do
            before { purchase.link.update!(native_type: Link::NATIVE_TYPE_COFFEE) }

            it "returns false" do
              expect(props[:show_download_button]).to eq(false)
            end
          end
        end
      end
    end

    describe "license_key" do
      context "when the purchase has a license" do
        include_context "when the purchase has a license"

        it "returns license key" do
          expect(props[:license_key]).to eq(purchase.license_key)
        end
      end

      context "when the purchase does not have a license" do
        it "returns nil" do
          expect(props[:license_key]).to be_nil
        end
      end
    end

    describe "product" do
      it "calls ProductPresenter#card_for_email" do
        expect(ProductPresenter).to receive(:card_for_email).with(product:).and_call_original
        expect(props[:product]).to be_present
      end
    end

    describe "gift_attributes" do
      context "when is not gift sender purchase" do
        it "returns an empty array" do
          expect(props[:gift_attributes]).to eq([])
        end
      end

      context "when is a gift sender purchase" do
        include_context "when is a gift sender purchase"

        it "returns gift attributes" do
          allow(purchase).to receive(:giftee_name_or_email).and_return("giftee_name_or_email")
          expect(props[:gift_attributes]).to eq(
            [
              { label: "Gift sent to", value: "giftee_name_or_email" },
              { label: "Message", value: "Hope you like it!" }
            ]
          )
        end

        context "when the gift note is empty" do
          before do
            gift.update!(gift_note: "  ")
          end

          it "doesn't return gift_message_attribute" do
            expect(props[:gift_attributes]).to eq(
              [
                { label: "Gift sent to", value: "giftee@example.com" },
              ]
            )
          end
        end
      end
    end

    describe "general_attributes" do
      context "when the purchase is not for membership" do
        context "when the purchase doesn't have a variant or quantity" do
          it "returns product price" do
            expect(props[:general_attributes]).to eq(
              [
                { label: "Product price", value: "$14.99" },
              ]
            )
          end

          context "when the purchase is in EUR" do
            before do
              purchase.update!(
                displayed_price_currency_type: Currency::EUR,
              )
              purchase.original_purchase.reload
            end

            it "returns product price in EUR" do
              expect(props[:general_attributes]).to eq(
                [
                  { label: "Product price", value: "€14.99" }
                ]
              )
            end
          end
        end

        context "when the purchase is a call purchase" do
          let!(:purchase) { create(:call_purchase, variant_attributes: [create(:variant, name: "1 hour")]) }

          it "returns general attributes including product price and duration" do
            presenter = described_class.new(purchase)
            expect(presenter.props[:general_attributes]).to eq(
              [
                { label: "Call schedule", value: [purchase.call.formatted_time_range, purchase.call.formatted_date_range] },
                { label: "Call link", value: "https://zoom.us/j/gmrd" },
                { label: "Duration", value: "1 hour" },
                { label: "Product price", value: "$1" },
              ]
            )
          end
        end

        context "when the purchase has variants and quantity" do
          let(:sizes_category) { create(:variant_category, title: "sizes", link: product) }
          let(:small_variant) { create(:variant, name: "small", price_difference_cents: 300, variant_category: sizes_category) }
          let(:colors_category) { create(:variant_category, title: "colors", link: product) }
          let(:red_variant) { create(:variant, name: "red", price_difference_cents: 300, variant_category: colors_category) }

          before do
            purchase.variant_attributes << small_variant
            purchase.variant_attributes << red_variant
            purchase.update!(quantity: 2)
          end

          it "returns general attributes with variant, price, and quantity" do
            expect(props[:general_attributes]).to eq(
              [
                { label: "Variant", value: "small, red" },
                { label: "Product price", value: "$7.49" },
                { label: "Quantity", value: 2 }
              ]
            )
          end

          context "when the purchase is free" do
            before do
              expect_any_instance_of(Purchase).to receive(:free_purchase?).and_return(true)
            end

            it "returns general attributes with variant and quantity and no product price" do
              expect(props[:general_attributes]).to eq(
                [
                  { label: "Variant", value: "small, red" },
                  { label: "Quantity", value: 2 }
                ]
              )
            end
          end

          context "when the purchase is a coffee purchase" do
            before { purchase.link.update!(native_type: Link::NATIVE_TYPE_COFFEE) }

            it "returns general attributes including donation and excluding variant and quantity" do
              expect(props[:general_attributes]).to eq(
                [{ label: "Donation", value: "$7.49" }]
              )
            end
          end

          context "when the purchase has a license" do
            include_context "when the purchase has a license"

            it "returns general attributes with variant, price, and quantity" do
              expect(props[:general_attributes]).to eq(
                [
                  { label: "Variant", value: "small, red" },
                  { label: "Product price", value: "$7.49" },
                  { label: "Quantity", value: 2 }
                ]
              )
            end

            context "when the purchase is a multi-seat license" do
              before do
                allow_any_instance_of(Purchase).to receive(:is_multiseat_license?).and_return(true)
              end

              it "returns quantity as seats" do
                expect(props[:general_attributes]).to eq(
                  [
                    { label: "Variant", value: "small, red" },
                    { label: "Product price", value: "$7.49" },
                    { label: "Number of seats", value: 2 }
                  ]
                )
              end
            end

            context "when the purchase contains only one quantity" do
              before do
                purchase.update!(quantity: 1)
              end

              it "returns general attributes with variant and product price only" do
                expect(props[:general_attributes]).to eq(
                  [
                    { label: "Variant", value: "small, red" },
                    { label: "Product price", value: "$14.99" },
                  ]
                )
              end
            end
          end
        end

        context "when the purchase is bundle" do
          let(:bundle) { create(:product, user: seller, is_bundle: true, name: "Bundle product") }
          let(:purchase) { create(:purchase, link: bundle) }

          let!(:product) { create(:product, user: seller, name: "Product") }
          let!(:bundle_product) { create(:bundle_product, bundle:, product:) }

          before do
            purchase.create_artifacts_and_send_receipt!
          end

          it "returns bundle attribute" do
            presenter = described_class.new(purchase.product_purchases.last)
            expect(presenter.props[:general_attributes]).to eq(
              [
                {
                  label: "Bundle",
                  value: link_to("Bundle product", bundle.long_url, target: "_blank")
                },
              ]
            )
          end
        end
      end

      context "when the purchase is for a membership" do
        let(:purchase) do
          create(
            :membership_purchase,
            link: product,
            price_cents: 1_998,
            created_at: DateTime.parse("January 1, 2023")
          )
        end

        it "returns general attributes with variant" do
        end

        context "when the purchase has quantity" do
          before do
            purchase.update!(quantity: 2)
          end

          it "returns general attributes with variant, price and quantity" do
            expect(props[:general_attributes]).to eq(
              [
                { label: "Product price", value: "$9.99" },
                { label: "Quantity", value: 2 }
              ]
            )
          end
        end
      end

      context "without custom_fields" do
        it "returns product price only" do
          expect(props[:general_attributes]).to eq(
            [
              { label: "Product price", value: "$14.99" },
            ]
          )
        end
      end

      context "with custom fields" do
        before do
          purchase.purchase_custom_fields << [
            build(:purchase_custom_field, field_type: CustomField::TYPE_TERMS, name: "https://example.com/terms", value: "true"),
            build(:purchase_custom_field, field_type: CustomField::TYPE_CHECKBOX, name: "Want free swag?", value: "true"),
            build(:purchase_custom_field, field_type: CustomField::TYPE_CHECKBOX, name: "Sure you want free swag?", value: nil),
            build(:purchase_custom_field, field_type: CustomField::TYPE_TEXT, name: "Address", value: "123 Main St")
          ]
        end

        it "includes correct custom fields" do
          expect(props[:general_attributes]).to eq(
            [
              {
                label: "Product price",
                value: "$14.99"
              },
              {
                label: "Terms and Conditions",
                value: '<a target="_blank" href="https://example.com/terms">https://example.com/terms</a>'
              },
              {
                label: "Want free swag?",
                value: "Yes"
              },
              {
                label: "Sure you want free swag?",
                value: "No"
              },
              {
                label: "Address",
                value: "123 Main St"
              }
            ]
          )
        end
      end

      context "when the purchase has a tip" do
        before { purchase.create_tip!(value_cents: 500) }

        it "includes tip price attribute" do
          expect(props[:general_attributes]).to include(
            { label: "Tip", value: "$5" }
          )
        end
      end
    end

    describe "#refund_policy_attribute" do
      context "when the purchase doesn't have a refund policy" do
        it "returns product price only" do
          expect(props[:general_attributes]).to eq(
            [
              { label: "Product price", value: "$14.99" },
            ]
          )
        end
      end

      context "when the purchase has a refund policy" do
        before do
          purchase.create_purchase_refund_policy!(
            title: "This is a product-level refund policy",
            fine_print: "This is the fine print of the refund policy."
          )
        end

        it "includes refund policy attribute" do
          expect(props[:general_attributes]).to eq(
            [
              { label: "Product price", value: "$14.99" },
              { label: "This is a product-level refund policy", value: "This is the fine print of the refund policy." },
            ]
          )
        end
      end

      context "when the purchase is a gift receiver purchase" do
        let(:gift) { create(:gift, gift_note: "Hope you like it!", giftee_email: "giftee@example.com") }
        let(:gifter_purchase) { create(:purchase, link: gift.link, gift_given: gift, is_gift_sender_purchase: true) }
        let(:purchase) { create(:purchase, link: gift.link, gift_received: gift, is_gift_receiver_purchase: true) }

        before do
          gifter_purchase.create_purchase_refund_policy!(
            title: "This is a product-level refund policy",
            fine_print: "This is the fine print of the refund policy."
          )
        end

        it "uses gifter_purchase's refund policy" do
          expect(item_info.send(:purchase)).to eq(gift.giftee_purchase)
          expect(props[:general_attributes]).to eq(
            [
              { label: "Product price", value: "$1" },
              { label: "This is a product-level refund policy", value: "This is the fine print of the refund policy." },
            ]
          )
        end
      end

      context "when the purchase is a bundle product purchase" do
        let(:bundle) { create(:product, user: seller, is_bundle: true, name: "Bundle product") }
        let(:purchase) { create(:purchase, link: bundle, seller:) }
        let!(:product) { create(:product, user: seller, name: "Product") }
        let!(:bundle_product) { create(:bundle_product, bundle:, product:) }

        before do
          purchase.create_purchase_refund_policy!(
            title: "Bundle refund policy",
            fine_print: "Bundle fine print."
          )
          purchase.create_artifacts_and_send_receipt!
        end

        it "uses the bundle purchase's refund policy" do
          presenter = described_class.new(purchase.product_purchases.last)
          expect(presenter.props[:general_attributes]).to eq(
            [
              {
                label: "Bundle",
                value: link_to("Bundle product", bundle.long_url, target: "_blank")
              },
              { label: "Bundle refund policy", value: "Bundle fine print." },
            ]
          )
        end
      end

      context "when the purchase is a bundle gift receiver purchase" do
        let(:bundle) { create(:product, user: seller, is_bundle: true, name: "Bundle product") }
        let(:gift) { create(:gift, gift_note: "Hope you like it!", giftee_email: "giftee@example.com", link: bundle) }
        let(:gifter_purchase) { create(:purchase, link: bundle, seller:, gift_given: gift, is_gift_sender_purchase: true) }
        let(:purchase) { create(:purchase, link: bundle, seller:, gift_received: gift, is_gift_receiver_purchase: true) }
        let!(:product) { create(:product, user: seller, name: "Product") }
        let!(:bundle_product) { create(:bundle_product, bundle:, product:) }

        before do
          gifter_purchase.create_purchase_refund_policy!(
            title: "Bundle gift refund policy",
            fine_print: "Bundle gift fine print."
          )
          purchase.create_artifacts_and_send_receipt!
        end

        it "uses the gifter bundle purchase's refund policy" do
          presenter = described_class.new(purchase.product_purchases.last)
          expect(presenter.props[:general_attributes]).to eq(
            [
              {
                label: "Bundle",
                value: link_to("Bundle product", bundle.long_url, target: "_blank")
              },
              { label: "Bundle gift refund policy", value: "Bundle gift fine print." },
            ]
          )
        end
      end
    end

    describe "#refund_policy_attribute" do
      context "when the purchase doesn't have a refund policy" do
        it "returns product price only" do
          expect(props[:general_attributes]).to eq(
            [
              { label: "Product price", value: "$14.99" },
            ]
          )
        end
      end

      context "when the purchase has a refund policy" do
        before do
          purchase.create_purchase_refund_policy!(
            title: "This is a product-level refund policy",
            fine_print: "This is the fine print of the refund policy."
          )
        end

        it "includes refund policy attribute" do
          expect(props[:general_attributes]).to eq(
            [
              { label: "Product price", value: "$14.99" },
              { label: "This is a product-level refund policy", value: "This is the fine print of the refund policy." },
            ]
          )
        end
      end

      context "when the purchase is a gift receiver purchase" do
        let(:gift) { create(:gift, gift_note: "Hope you like it!", giftee_email: "giftee@example.com") }
        let(:gifter_purchase) { create(:purchase, link: gift.link, gift_given: gift, is_gift_sender_purchase: true) }
        let(:purchase) { create(:purchase, link: gift.link, gift_received: gift, is_gift_receiver_purchase: true) }

        before do
          gifter_purchase.create_purchase_refund_policy!(
            title: "This is a product-level refund policy",
            fine_print: "This is the fine print of the refund policy."
          )
        end

        it "uses gifter_purchase's refund policy" do
          expect(item_info.send(:purchase)).to eq(gift.giftee_purchase)
          expect(props[:general_attributes]).to eq(
            [
              { label: "Product price", value: "$1" },
              { label: "This is a product-level refund policy", value: "This is the fine print of the refund policy." },
            ]
          )
        end
      end
    end

    describe "manage_subscription_note" do
      context "when the purchase is not a subscription" do
        it "returns nil" do
          expect(props[:manage_subscription_note]).to be_nil
        end
      end

      context "when the purchase is a membership" do
        let(:product) { create(:membership_product) }
        let(:purchase) { create(:membership_purchase, link: product, total_transaction_cents: 1_499) }

        it "returns subscription note" do
          url = Rails.application.routes.url_helpers.manage_subscription_url(
            purchase.subscription.external_id,
            host: UrlService.domain_with_protocol,
          )
          expect(props[:manage_subscription_note]).to eq(
            "You will be charged once a month. If you would like to manage your membership you can visit " \
            "<a target=\"_blank\" href=\"#{url}\">subscription settings</a>."
          )
        end

        context "when not used in an email" do
          let(:for_email) { false }

          it "requires email confirmation in the subscription settings link" do
            url = Rails.application.routes.url_helpers.manage_subscription_url(
              purchase.subscription.external_id,
              host: UrlService.domain_with_protocol,
            )
            expect(props[:manage_subscription_note]).to eq(
              "You will be charged once a month. If you would like to manage your membership you can visit " \
              "<a target=\"_blank\" href=\"#{url}\">subscription settings</a>."
            )
          end
        end

        context "when the subscription is a gift" do
          before do
            allow(purchase.subscription).to receive(:gift?).and_return(true)
            allow(purchase).to receive(:giftee_name_or_email).and_return("giftee@gumroad.com")
          end

          context "when the purchase is a gift sender purchase" do
            it "returns gift subscription note" do
              note = "Note that giftee@gumroad.com’s membership will not automatically renew."
              expect(props[:manage_subscription_note]).to eq(note)
            end
          end

          context "when the purchase is a gift receiver purchase" do
            let(:gift) { create(:gift, gift_note: "Gift note") }
            let!(:gifter_purchase) { create(:purchase, link: gift.link, gift_given: gift, is_gift_sender_purchase: true) }
            let(:purchase) { create(:purchase, link: gift.link, gift_received: gift, is_gift_receiver_purchase: true) }

            it "returns nil" do
              expect(props[:manage_subscription_note]).to be_nil
            end
          end
        end
      end

      context "when the purchase is an installment plan" do
        it "returns the installment plan manage note with dates and link" do
          travel_to(Time.zone.parse("2025-03-14"))

          product_installment_plan = create(
            :product_installment_plan,
            number_of_installments: 5,
            recurrence: "monthly",
          )
          purchase = create(:installment_plan_purchase, link: product_installment_plan.link)
          subscription = purchase.subscription

          props = described_class.new(purchase).props

          url = Rails.application.routes.url_helpers.manage_subscription_url(
            subscription.external_id,
            host: UrlService.domain_with_protocol,
          )
          expect(props[:manage_subscription_note]).to eq(
            "Installment plan initiated on Mar 14, 2025. " \
            "Your final charge will be on Aug 14, 2025. " \
            "You can manage your payment settings <a target=\"_blank\" href=\"#{url}\">here</a>."
          )
        end
      end
    end

    describe "commission deposit purchase", :vcr do
      let(:purchase) { create(:commission_deposit_purchase) }
      let(:item_info) { described_class.new(purchase) }

      before do
        purchase.create_artifacts_and_send_receipt!
        purchase.reload
      end

      it "returns the correct product price" do
        props = item_info.props

        expect(props[:general_attributes]).to include(
          { label: "Product price", value: "$2" }
        )
      end
    end
  end
end
