# frozen_string_literal: true

require "spec_helper"
require "shared_examples/receipt_presenter_concern"

describe ReceiptPresenter::PaymentInfo do
  include ActionView::Helpers::UrlHelper

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, name: "Digital product") }
  let(:purchase) do
    create(
      :purchase,
      link: product,
      seller:,
      price_cents: 1_499,
      created_at: DateTime.parse("January 1, 2023")
    )
  end
  let(:payment_info) { described_class.new(purchase) }
  let(:invoice_url) do
    Rails.application.routes.url_helpers.generate_invoice_by_buyer_url(
      purchase.external_id,
      email: purchase.email,
      host: UrlService.domain_with_protocol
    )
  end

  describe ".new" do
    let(:subscription) { create(:subscription) }

    context "with a Purchase" do
      it "assigns the purchase to instance variables" do
        expect(payment_info.send(:chargeable)).to eq(purchase)
        expect(payment_info.send(:orderable)).to eq(purchase)
      end
    end

    context "with a Charge", :vcr do
      let(:charge) { create(:charge) }
      let(:payment_info) { described_class.new(charge) }

      before do
        charge.purchases << purchase
        charge.order.purchases << purchase
      end

      it "assigns the charge and order to instance variables" do
        expect(payment_info.send(:chargeable)).to eq(charge)
        expect(payment_info.send(:orderable)).to eq(charge.order)
      end
    end
  end

  describe "#title" do
    context "when is not a recurring subscription charge" do
      it "returns correct title" do
        expect(payment_info.title).to eq("Payment info")
      end
    end

    context "when the purchase is recurring subscription" do
      include_context "when the purchase is recurring subscription"

      it "returns correct title" do
        expect(payment_info.title).to eq("Thank you for your payment!")
      end
    end
  end

  describe "payment attributes" do
    let(:today_payment_attributes) { payment_info.today_payment_attributes }
    let(:upcoming_payment_attributes) { payment_info.upcoming_payment_attributes }

    RSpec.shared_examples "payment attributes for single purchase" do
      context "when is gift receiver purchase" do
        let(:gift) { create(:gift, gift_note: "Hope you like it!", giftee_email: "giftee@example.com") }
        let(:purchase) { create(:purchase, link: gift.link, gift_received: gift, is_gift_receiver_purchase: true) }

        it "returns an empty arrays" do
          expect(today_payment_attributes).to eq([])
          expect(upcoming_payment_attributes).to eq([])
        end
      end

      context "when is gift sender purchase" do
        let(:gift) { create(:gift, gift_note: "Hope you like it!", giftee_email: "giftee@example.com") }
        let(:purchase) { create(:purchase, link: gift.link, gift_received: gift, is_gift_sender_purchase: true) }

        it "returns an empty array for upcoming payment" do
          expect(upcoming_payment_attributes).to eq([])
        end
      end

      context "when is a membership purchase" do
        let(:product) { create(:membership_product, name: "Membership product") }
        let(:purchase) do
          create(
            :membership_purchase,
            link: product,
            price_cents: 1_998,
            created_at: DateTime.parse("January 1, 2023")
          )
        end

        context "with shipping and tax" do
          before do
            purchase.update!(
              was_purchase_taxable: true,
              displayed_price_cents: 1_744,
              tax_cents: 254,
              shipping_cents: 499,
              total_transaction_cents: 1_744 + 254 + 499
            )
            # Skip validation that triggers "Validation failed: We couldn't charge your card. Try again or use a different card."
            purchase.update_column(:price_cents, 1_744)
          end

          it "returns pricing attributes" do
            expect(today_payment_attributes).to eq(
              [
                { label: "Today's payment", value: nil },
                { label: "Membership product", value: "$17.44" },
                { label: "Shipping", value: "$4.99" },
                { label: "Sales tax (included)", value: "$2.54" },
                { label: "Amount paid", value: "$24.97" },
                { label: nil, value: link_to("Generate invoice", invoice_url) },
              ]
            )
          end

          context "when the purchase is in EUR" do
            before do
              purchase.link.default_price.update!(currency: Currency::EUR)
              purchase.link.update!(price_currency_type: Currency::EUR)
              purchase.update!(
                displayed_price_currency_type: Currency::EUR,
                rate_converted_to_usd: 1.07,
                displayed_price_cents: 1_866 # 17.44 * 1.07
              )
              purchase.original_purchase.reload
            end

            it "returns today's pricing attributes in USD" do
              expect(today_payment_attributes).to eq(
                [
                  { label: "Today's payment", value: nil },
                  { label: "Membership product", value: "$17.44" },
                  { label: "Shipping", value: "$4.99" },
                  { label: "Sales tax (included)", value: "$2.54" },
                  { label: "Amount paid", value: "$24.97" },
                  { label: nil, value: link_to("Generate invoice", invoice_url) },
                ]
              )
            end
          end

          context "when the purchase is recurring subscription" do
            include_context "when the purchase is recurring subscription" do
              let(:purchase_attributes) do
                {
                  was_purchase_taxable: true,
                  displayed_price_cents: 1_744,
                  tax_cents: 254,
                  shipping_cents: 499,
                  total_transaction_cents: 1_744 + 254 + 499,
                  created_at: DateTime.parse("January 1, 2023"),
                }
              end
            end

            before do
              purchase.subscription.original_purchase.update!(purchase_attributes)
            end

            it "returns today's pricing attributes in USD" do
              expect(today_payment_attributes).to eq(
                [
                  { label: "Today's payment", value: nil },
                  { label: "Membership product", value: "$17.44" },
                  { label: "Shipping", value: "$4.99" },
                  { label: "Sales tax (included)", value: "$2.54" },
                  { label: "Amount paid", value: "$24.97" },
                  { label: nil, value: link_to("Generate invoice", invoice_url) },
                ]
              )
            end
          end
        end

        context "when the purchase is a free trial" do
          let(:purchase) do
            create(
              :free_trial_membership_purchase,
              price_cents: 3_00,
              created_at: Date.parse("Jan 1, 2023")
            )
          end

          before do
            purchase.link.update!(name: "Membership with trial")
            purchase.subscription.update!(free_trial_ends_at: Date.parse("Jan 8, 2023"))
          end

          it "returns today's payment attributes" do
            expect(today_payment_attributes).to eq(
              [
                { label: "Today's payment", value: nil },
                { label: "Membership with trial", value: "$0" },
              ]
            )
          end

          it "returns upcoming payment attributes" do
            expect(upcoming_payment_attributes).to eq(
              [
                { label: "Upcoming payment", value: nil },
                { label: "Membership with trial", value: "$3 on Jan 8, 2023" },
              ]
            )
          end

          context "when the purchase includes tax" do
            before do
              purchase.update!(
                was_purchase_taxable: true,
                tax_cents: 120,
                total_transaction_cents: purchase.total_transaction_cents + 120,
                displayed_price_cents: purchase.displayed_price_cents + 120
              )
            end

            it "return today's payment attributes with product price and tax as zeros" do
              purchase.subscription.original_purchase.reload
              expect(today_payment_attributes).to eq(
                [
                  { label: "Today's payment", value: nil },
                  { label: "Membership with trial", value: "$0" },
                  { label: "Sales tax (included)", value: "$0" },
                  { label: "Amount paid", value: "$0" },
                ]
              )
            end

            it "returns upcoming payment attributes" do
              purchase.subscription.original_purchase.reload
              expect(upcoming_payment_attributes).to eq(
                [
                  { label: "Upcoming payment", value: nil },
                  { label: "Membership with trial", value: "$5.40 on Jan 8, 2023" },
                ]
              )
            end
          end
        end

        context "when the purchase has fixed length" do
          context "when the purchase is a free trial" do
            let(:purchase) do
              create(
                :free_trial_membership_purchase,
                price_cents: 3_00,
                created_at: Date.parse("Jan 1, 2023")
              )
            end

            before do
              purchase.link.update!(name: "Membership product")
              purchase.subscription.update!(
                free_trial_ends_at: Date.parse("Jan 8, 2023"),
                charge_occurrence_count: 2
              )
            end

            it "returns today's payment attributes" do
              expect(today_payment_attributes).to eq(
                [
                  { label: "Today's payment", value: nil },
                  { label: "Membership product (free trial)", value: "$0" },
                ]
              )
            end

            it "returns upcoming payment attributes" do
              expect(upcoming_payment_attributes).to eq(
                [
                  { label: "Upcoming payment", value: nil },
                  { label: "Membership product: 1 of 2", value: "$3 on Jan 8, 2023" },
                ]
              )
            end
          end

          context "when there is at least one more remaining charge" do
            before do
              purchase.subscription.update!(charge_occurrence_count: 2)
            end

            it "returns today's payment attributes" do
              purchase.subscription.original_purchase.reload
              expect(today_payment_attributes).to eq(
                [
                  { label: "Today's payment", value: nil },
                  { label: "Membership product: 1 of 2", value: "$19.98" },
                  { label: nil, value: link_to("Generate invoice", invoice_url) },
                ]
              )
            end

            it "returns upcoming payment attributes" do
              purchase.subscription.original_purchase.reload
              expect(upcoming_payment_attributes).to eq(
                [
                  { label: "Upcoming payment", value: nil },
                  { label: "Membership product: 2 of 2", value: "$19.98 on Feb 1, 2023" },
                ]
              )
            end
          end

          context "when there are no more remaining charges" do
            before do
              purchase.subscription.update!(charge_occurrence_count: 1)
            end

            it "does not includes today's payment header and upcoming payments" do
              expect(today_payment_attributes).to eq(
                [
                  { label: "Membership product: 1 of 1", value: "$19.98 - This is the final payment. You will not be charged for this product again." },
                  { label: nil, value: link_to("Generate invoice", invoice_url) },
                ]
              )
            end

            it "returns empty upcoming payment attributes" do
              expect(upcoming_payment_attributes).to eq([])
            end
          end
        end
      end

      context "when is not a membership purchase" do
        context "when the purchase is free" do
          let(:purchase) { create(:free_purchase) }

          it "returns an empty arrays for payment attributes" do
            expect(today_payment_attributes).to eq([])
            expect(upcoming_payment_attributes).to eq([])
          end
        end

        context "when the purchase is for digital product" do
          context "when there is only 1 qty" do
            it "returns today's pricing attribute with product price" do
              expect(today_payment_attributes).to eq(
                [
                  { label: "Digital product", value: "$14.99" },
                  { label: nil, value: link_to("Generate invoice", invoice_url) },
                ]
              )
            end

            it "returns empty upcoming payment attributes" do
              expect(upcoming_payment_attributes).to eq([])
            end

            context "when the purchase is in EUR" do
              before do
                purchase.link.update!(price_currency_type: Currency::EUR, price_cents: 1499)
                purchase.update!(
                  displayed_price_currency_type: Currency::EUR,
                  rate_converted_to_usd: 1.07,
                  displayed_price_cents: purchase.price_cents * 1.07 # 14.99 * 1.07
                )
                purchase.original_purchase.reload
              end

              it "returns today's pricing attributes in USD" do
                expect(today_payment_attributes).to eq(
                  [
                    { label: "Digital product", value: "$14.98" },
                    { label: nil, value: link_to("Generate invoice", invoice_url) },
                  ]
                )
              end
            end

            context "when the purchase is taxable" do
              before do
                purchase.update!(
                  was_purchase_taxable: true,
                  tax_cents: 254,
                  displayed_price_cents: 1_744,
                  price_cents: 1_744,
                  total_transaction_cents: 1_744 + 254
                )
              end

              it "returns today's pricing attributes with product name and sales tax" do
                expect(today_payment_attributes).to eq(
                  [
                    { label: "Digital product", value: "$17.44" },
                    { label: "Sales tax (included)", value: "$2.54" },
                    { label: "Amount paid", value: "$19.98" },
                    { label: nil, value: link_to("Generate invoice", invoice_url) },
                  ]
                )
              end

              it "returns empty upcoming payment attributes" do
                expect(upcoming_payment_attributes).to eq([])
              end
            end
          end

          context "when the quantity is greater than 1" do
            before do
              purchase.update!(
                quantity: 2,
                displayed_price_cents: purchase.displayed_price_cents * 2,
                price_cents: purchase.displayed_price_cents * 2,
                total_transaction_cents: purchase.displayed_price_cents * 2
              )
            end

            context "when there is no tax or shipping" do
              it "returns today's pricing attributes without amount paid" do
                expect(today_payment_attributes).to eq(
                  [
                    { label: "Digital product × 2", value: "$29.98" },
                    { label: nil, value: link_to("Generate invoice", invoice_url) },
                  ]
                )
              end

              it "returns empty upcoming payment attributes" do
                expect(upcoming_payment_attributes).to eq([])
              end
            end

            context "when the purchase has a license with quantity" do
              include_context "when the purchase has a license"

              it "returns today's pricing attributes with quantity" do
                expect(today_payment_attributes).to eq(
                  [
                    { label: "Digital product × 2", value: "$29.98" },
                    { label: nil, value: link_to("Generate invoice", invoice_url) },
                  ]
                )
              end

              it "returns empty upcoming payment attributes" do
                expect(upcoming_payment_attributes).to eq([])
              end
            end

            context "when the purchase is taxable" do
              before do
                purchase.update!(
                  was_purchase_taxable: true,
                  tax_cents: 254,
                  displayed_price_cents: 1_744,
                  price_cents: 1_744,
                  total_transaction_cents: 1_744 + 254
                )
              end

              it "returns today's pricing attributes with subtotal, quantity, sales tax" do
                expect(today_payment_attributes).to eq(
                  [
                    { label: "Digital product × 2", value: "$17.44" },
                    { label: "Sales tax (included)", value: "$2.54" },
                    { label: "Amount paid", value: "$19.98" },
                    { label: nil, value: link_to("Generate invoice", invoice_url) },
                  ]
                )
              end

              it "returns empty upcoming payment attributes" do
                expect(upcoming_payment_attributes).to eq([])
              end
            end
          end
        end

        context "when the purchase is for a physical product" do
          include_context "when the purchase is for a physical product"

          before do
            purchase.update!(
              was_purchase_taxable: true,
              displayed_price_cents: 1_499,
              price_cents: 1_499, # shipping included
              tax_cents: 254,
              shipping_cents: 499,
              total_transaction_cents: 1_499 + 254 + 499
            )
            purchase.link.update!(name: "Physical product")
          end

          it "returns today's pricing attributes" do
            expect(today_payment_attributes).to eq(
              [
                { label: "Physical product", value: "$14.99" },
                { label: "Shipping", value: "$4.99" },
                { label: "Sales tax (included)", value: "$2.54" },
                { label: "Amount paid", value: "$22.52" },
                { label: nil, value: link_to("Generate invoice", invoice_url) },
              ]
            )
          end

          it "returns empty upcoming payment attributes" do
            expect(upcoming_payment_attributes).to eq([])
          end
        end
      end

      context "when the purchase is a commission deposit purchase", :vcr do
        let(:purchase) { create(:commission_deposit_purchase, price_cents: 200) }
        let(:payment_info) { described_class.new(purchase) }

        before { purchase.create_artifacts_and_send_receipt! }

        it "returns correct today payment attributes" do
          expect(payment_info.today_payment_attributes).to eq(
            [
              { label: "Today's payment", value: nil },
              { label: "The Works of Edgar Gumstein", value: "$1" },
              { label: nil, value: link_to("Generate invoice", invoice_url) }
            ]
          )
        end

        it "returns correct upcoming payment attributes" do
          expect(payment_info.upcoming_payment_attributes).to eq(
            [
              { label: "Upcoming payment", value: nil },
              { label: "The Works of Edgar Gumstein", value: "$1 on completion" }
            ]
          )
        end
      end
    end

    context "with a Purchase" do
      it_behaves_like "payment attributes for single purchase"
    end

    context "with a Charge", :vcr do
      let(:charge) { create(:charge) }
      let(:invoice_url) do
        purchase = charge.send(:purchase_as_chargeable)
        Rails.application.routes.url_helpers.generate_invoice_by_buyer_url(
          purchase.external_id,
          email: purchase.email,
          host: UrlService.domain_with_protocol
        )
      end
      let(:payment_info) { described_class.new(charge) }

      before do
        charge.purchases << purchase
        charge.order.purchases << purchase
      end

      it_behaves_like "payment attributes for single purchase"

      context "with multiple purchases" do
        let(:purchase_two) do
          create(
            :purchase,
            link: create(:product, name: "Product Two", user: seller),
            seller:,
            price_cents: 999
          )
        end
        let(:purchase_three) do
          create(
            :purchase,
            link: create(:product, name: "Product Three", user: seller),
            seller:,
            price_cents: 499
          )
        end

        before do
          charge.purchases << purchase_two
          charge.purchases << purchase_three
          charge.order.purchases << purchase_two
          charge.order.purchases << purchase_three
        end

        it "includes both purchases with amount paid" do
          expect(today_payment_attributes).to eq(
            [
              { label: "Digital product", value: "$14.99" },
              { label: "Product Two", value: "$9.99" },
              { label: "Product Three", value: "$4.99" },
              { label: "Amount paid", value: "$29.97" },
              { label: nil, value: link_to("Generate invoice", invoice_url) },
            ]
          )
        end

        context "when purchases have shipping and tax" do
          before do
            purchase_two.update!(
              was_purchase_taxable: true,
              displayed_price_cents: 999, # in product currency, USD
              tax_cents: 120,
              shipping_cents: 250,
              total_transaction_cents: 999 + 120 + 250
            )
            purchase_three.update!(
              was_purchase_taxable: true,
              displayed_price_cents: 499, # in product currency, USD
              tax_cents: 59,
              shipping_cents: 150,
              total_transaction_cents: 499 + 59 + 150
            )
          end

          it "sums amounts" do
            expect(today_payment_attributes).to eq(
              [
                { label: "Digital product", value: "$14.99" },
                { label: "Product Two", value: "$9.99" },
                { label: "Product Three", value: "$4.99" },
                { label: "Shipping", value: "$4" }, # 2.50 + 1.5
                { label: "Sales tax (included)", value: "$1.79" }, # 1.2 + 0.59
                { label: "Amount paid", value: "$35.76" },
                { label: nil, value: link_to("Generate invoice", invoice_url) },
              ]
            )
          end
        end
      end
    end
  end

  describe "#recurring_subscription_notes" do
    context "when is not a recurring subscription charge" do
      it "returns nil" do
        expect(payment_info.send(:recurring_subscription_notes)).to be_nil
      end
    end

    context "when the purchase is recurring subscription" do
      include_context "when the purchase is recurring subscription"

      it "returns note content" do
        expect(payment_info.send(:recurring_subscription_notes).first).to include(
          "We have successfully processed the payment for your recurring subscription"
        )
      end
    end

    context "when the purchase is an installment payment" do
      let(:product) { create(:product, :with_installment_plan, user: seller, name: "Installment product") }
      let(:original_installment_purchase) { create(:installment_plan_purchase, link: product) }
      let(:purchase) do
        create(
          :recurring_installment_plan_purchase,
          subscription: original_installment_purchase.subscription,
          link: product
        )
      end

      it "returns installment-specific note content" do
        note = payment_info.send(:recurring_subscription_notes).first
        expect(note).to include("We have successfully processed the installment payment for")
        expect(note).to include(product.name)
      end
    end
  end

  describe "#usd_currency_note" do
    it "returns note content" do
      expect(payment_info.send(:usd_currency_note)).to eq(
        "All charges are processed in United States Dollars. " +
        "Your bank or financial institution may apply their own fees for currency conversion."
      )
    end
  end

  describe "#credit_card_note" do
    RSpec.shared_examples "credit card note" do
      it "returns note content" do
        expect(payment_info.send(:credit_card_note)).to eq(
          "The charge will be listed as GUMRD.COM* on your credit card statement."
        )
      end

      context "when the card_type is blank" do
        before { purchase.update!(card_type: nil) }

        it "returns nil" do
          expect(payment_info.send(:credit_card_note)).to be_nil
        end
      end

      context "when the card_type is paypal" do
        before { purchase.update!(card_type: CardType::PAYPAL) }

        it "returns nil" do
          purchase.update!(card_type: CardType::PAYPAL)
          expect(payment_info.send(:credit_card_note)).to be_nil
        end
      end
    end

    context "with a Purchase" do
      it_behaves_like "credit card note"
    end

    context "with a Charge", :vcr do
      let(:charge) { create(:charge) }
      let(:payment_info) { described_class.new(charge) }

      before do
        charge.purchases << purchase
        charge.order.purchases << purchase
      end

      it_behaves_like "credit card note"
    end
  end

  describe "#notes" do
    include_context "when the purchase is recurring subscription"

    it "returns all notes" do
      expect(payment_info.notes.size).to eq(3)
      expect(payment_info.notes[0]).to include(
        "We have successfully processed the payment for your recurring subscription"
      )
      expect(payment_info.notes[1]).to eq(
        "All charges are processed in United States Dollars. " +
        "Your bank or financial institution may apply their own fees for currency conversion."
      )
      expect(payment_info.notes[2]).to eq(
        "The charge will be listed as GUMRD.COM* on your credit card statement."
      )
    end
  end

  describe "#payment_method_attribute" do
    RSpec.shared_examples "payment method attribute" do
      it "returns payment method attribute" do
        expect(payment_info.payment_method_attribute).to eq(
          { label: "Payment method", value: "VISA *4062" }
        )
      end

      context "when the purchase is a free trial" do
        let(:purchase) { create(:free_trial_membership_purchase) }

        it "returns nil" do
          expect(payment_info.payment_method_attribute).to be_nil
        end
      end

      context "when the purchase is a free purchase" do
        let(:purchase) { create(:free_purchase) }

        it "returns nil" do
          expect(payment_info.payment_method_attribute).to be_nil
        end
      end
    end

    describe "#today_membership_paid_until_attribute" do
      context "when is not a recurring subscription charge" do
        it "returns nil" do
          expect(payment_info.send(:today_membership_paid_until_attribute)).to be_nil
        end
      end

      context "when the purchase is recurring subscription" do
        let(:purchase) { create(:recurring_membership_purchase) }

        context "when is gift sender purchase" do
          before do
            purchase.update!(is_gift_sender_purchase: true)
          end

          it "return the paid until date" do
            expect(payment_info.send(:today_membership_paid_until_attribute)).to eq(
              {
                label: "Membership paid for until",
                value: purchase.subscription.end_time_of_subscription.to_fs(:formatted_date_abbrev_month)
              }
            )
          end
        end

        context "when is not gift sender purchase" do
          it "returns nil" do
            expect(payment_info.send(:today_membership_paid_until_attribute)).to be_nil
          end
        end

        context "when the purchase is not a subscription" do
          before do
            allow(purchase).to receive(:subscription).and_return(nil)
          end

          it "returns nil" do
            expect(payment_info.send(:today_membership_paid_until_attribute)).to be_nil
          end
        end
      end
    end

    context "with a Purchase" do
      it_behaves_like "payment method attribute"
    end

    context "with a Charge", :vcr do
      let(:charge) { create(:charge) }
      let(:payment_info) { described_class.new(charge) }

      before do
        charge.purchases << purchase
        charge.order.purchases << purchase
      end

      it_behaves_like "payment method attribute"

      context "with two free purchases" do
        let(:purchase) { create(:free_purchase) }
        let(:purchase_two) { create(:free_purchase) }

        before do
          charge.purchases << purchase_two
          charge.order.purchases << purchase_two
        end

        it "returns nil" do
          expect(payment_info.payment_method_attribute).to be_nil
        end

        context "when the second purchase is not free" do
          let(:purchase_two) { create(:purchase) }

          it "returns payment method attribute" do
            expect(payment_info.payment_method_attribute).to eq(
              { label: "Payment method", value: "VISA *4062" }
            )
          end
        end
      end
    end
  end
end
