# frozen_string_literal: true

require "spec_helper"

describe CustomerMailer do
  describe "receipt" do
    subject(:mail) do
      user = create(:user, email: "bob@gumroad.com", name: "bob walsh")
      link = create(:product, user:)

      @purchase = create(:purchase, link:, seller: link.user, email: "to@example.org")
      @purchase.create_url_redirect!

      user_2 = create(:user, email: "bobby@gumroad.com")
      link_2 = create(:product, user: user_2)
      @purchase_2 = create(:purchase, link: link_2, seller: link_2.user)
      @purchase_2.create_url_redirect!

      CustomerMailer.receipt(@purchase.id)
    end

    it "renders the headers for a receipt" do
      expect(mail.subject).to eq "You bought #{@purchase.link.name}!"
      expect(mail.to).to eq(["to@example.org"])
      expect(mail[:from].value).to eq("#{@purchase.link.user.name} <noreply@#{CUSTOMERS_MAIL_DOMAIN}>")
      expect(mail[:reply_to].value).to eq("bob@gumroad.com")
    end

    context "when support email exists" do
      subject(:mail) do
        user = create(:user, email: "bob@gumroad.com", name: "bob walsh")
        link = create(:product, user:, support_email: "support@example.com")

        @purchase = create(:purchase, link:, seller: link.user, email: "to@example.org")
        @purchase.create_url_redirect!

        CustomerMailer.receipt(@purchase.id)
      end

      it "uses correct support email" do
        expect(mail[:reply_to].value).to eq("support@example.com")
      end
    end

    it "renders the headers with UrlRedirect" do
      user = create(:user, email: "bob@gumroad.com", name: "bob walsh, LLC")
      link = create(:product, user:)
      purchase = create(:purchase, link:, seller: link.user)
      purchase.create_url_redirect!
      mail = CustomerMailer.receipt(purchase.id)
      expect(mail[:from].value).to eq("\"#{user.name}\" <noreply@#{CUSTOMERS_MAIL_DOMAIN}>")
      expect(mail[:reply_to].value).to eq("bob@gumroad.com")
    end

    context "when user name contains special characters" do
      before do
        @user = create(:user)
        @product = create(:product, user: @user)
        @purchase = create(:purchase, link: @product, seller: @product.user)
        @purchase.create_url_redirect!
      end

      context "with Spanish letters" do
        it "sets the FROM name to the creator's name" do
          @user.update!(name: "Juan Girão")
          mail = CustomerMailer.receipt(@purchase.id)
          expect(mail.header.to_s).to include(Mail::Address.new("#{@user.name} <noreply@staging.customers.gumroad.com>").encoded)
        end

        context "and symbols" do
          it "sets the FROM name to 'Gumroad'" do
            @user.update!(name: "Juan Girão @ Gumroad")
            mail = CustomerMailer.receipt(@purchase.id)
            expect(mail.header.to_s).to include("From: Gumroad <noreply@staging.customers.gumroad.com>")
          end
        end
      end

      context "with Romanian letters" do
        it "sets the FROM name to the creator's name" do
          @user.update!(name: "Ștefan Opriță")
          mail = CustomerMailer.receipt(@purchase.id)
          expect(mail.header.to_s).to include(Mail::Address.new("#{@user.name} <noreply@staging.customers.gumroad.com>").encoded)
        end

        context "and symbols" do
          it "sets the FROM name to 'Gumroad'" do
            @user.update!(name: "Ștefan Opriță @ Gumroad")
            mail = CustomerMailer.receipt(@purchase.id)
            expect(mail.header.to_s).to include("From: Gumroad <noreply@staging.customers.gumroad.com>")
          end
        end
      end

      context "with Asian letters" do
        it "sets the FROM name to the creator's name" do
          @user.update!(name: "ゆうさん")
          mail = CustomerMailer.receipt(@purchase.id)
          expect(mail.header.to_s).to include(Mail::Address.new("#{@user.name} <noreply@staging.customers.gumroad.com>").encoded)
        end

        context "and symbols" do
          it "sets the FROM name to the creator's name" do
            @user.update!(name: "ゆうさん @ Gumroad")
            mail = CustomerMailer.receipt(@purchase.id)
            expect(mail.header.to_s).to include(Mail::Address.new("#{@user.name} <noreply@staging.customers.gumroad.com>").encoded)
          end
        end
      end

      context "with ASCII symbols" do
        it "wraps creator name in quotes" do
          @user.update!(name: "Gumbot @ Gumroad")
          mail = CustomerMailer.receipt(@purchase.id)
          expect(mail.header.to_s).to include("From: \"Gumbot @ Gumroad\" <noreply@staging.customers.gumroad.com>")
        end
      end

      context "with new line characters and leading blank spaces" do
        it "deletes the new lines and strips whitespaces from the creator name" do
          @user.update!(name: "   \nGumbot\n Generalist @ Gumroad   ")
          mail = CustomerMailer.receipt(@purchase.id)
          expect(mail.header.to_s).to include("From: \"Gumbot Generalist @ Gumroad\" <noreply@staging.customers.gumroad.com>")
        end
      end
    end

    it "has no-reply when creator uses messaging" do
      product = create(:product, user: create(:user))
      mail = CustomerMailer.receipt(create(:purchase, link: product).id)
      expect(mail[:from].value).to match("noreply@#{CUSTOMERS_MAIL_DOMAIN}")
    end

    it "renders the body" do
      expect(mail.body.sanitized).to match(@purchase.link_name)
      expect(mail.body.sanitized).to have_text(
        "All charges are processed in United States Dollars. " +
        "Your bank or financial institution may apply their own fees for currency conversion."
      )
      expect(mail.body.sanitized).to have_text("The charge will be listed as GUMRD.COM* on your credit card statement.")
    end

    it "has the right subject for a purchase" do
      expect(mail.subject).to match(/^You bought /)
    end

    context "when the purchase is free" do
      let(:seller) { create(:user, email: "alice@gumroad.com", name: "alice nguyen") }
      let(:product) { create(:product, user: seller, price_cents: 0) }
      let(:purchase) do
        create(:purchase, link: product, seller:, email: "buyer@example.com", price_cents: 0, stripe_transaction_id: nil, stripe_fingerprint: nil, purchaser: create(:user))
      end

      before do
        purchase.create_url_redirect!
      end

      it "has the right subject" do
        expect(CustomerMailer.receipt(purchase.id).subject).to match(/^You got /)
      end

      it "does not include generate invoice section" do
        mail = CustomerMailer.receipt(purchase.id)
        expect(mail.body.encoded).not_to have_link("Generate invoice")
      end
    end

    it "has the right subject for a rental purchase" do
      user = create(:user, email: "alice@gumroad.com", name: "alice nguyen")
      link = create(:product_with_video_file, user:, purchase_type: :buy_and_rent, price_cents: 500, rental_price_cents: 0)
      purchase = create(:purchase, link:, seller: user, email: "somewhere@gumroad.com", price_cents: 0, stripe_transaction_id: nil,
                                   stripe_fingerprint: nil, is_rental: true)
      purchase.create_url_redirect!
      expect(CustomerMailer.receipt(purchase.id).subject).to match(/^You rented /)
    end

    it "has the right subject for an original subscription purchase" do
      purchase = create(:membership_purchase)

      purchase.create_url_redirect!
      expect(CustomerMailer.receipt(purchase.id).subject).to match(/^You've subscribed to /)
    end

    context "when the purchase is for a recurring subscription" do
      let(:purchase) { create(:recurring_membership_purchase) }
      subject(:mail) { CustomerMailer.receipt(purchase.id) }

      before do
        purchase.create_url_redirect!
      end


      it "has the right subject for a recurring subscription purchase" do
        expect(mail.subject).to match(/^Recurring charge for /)
      end

      it "has the right subject for a subscription upgrade purchase" do
        purchase.is_upgrade_purchase = true
        purchase.save!

        expect(mail.subject).to match(/^You've upgraded your membership for /)
      end

      it "includes recurring subscription specific content" do
        mail = CustomerMailer.receipt(purchase.id)
        expect(mail.body.sanitized).to have_text("Thank you for your payment!")
        expect(mail.body.sanitized).to include(
          "We have successfully processed the payment for your recurring subscription to"
        )
        expect(mail.body.sanitized).to have_text(
          "You will be charged once a month. " \
          "If you would like to manage your membership you can visit subscription settings."
        )
      end
    end

    it "does not have the download link in the receipt if link has no content" do
      user = create(:user)
      link = create(:product, user:)
      purchase = create(:purchase, link:, seller: link.user)
      purchase.url_redirect = UrlRedirect.create!(purchase:, link:)
      purchase.save

      mail = CustomerMailer.receipt(purchase.id)
      expect(mail.body.sanitized).to_not match("Download")
    end

    describe "Recommended products section" do
      let(:seller) { create(:named_seller) }
      let(:product) { create(:product, user: seller, name: "Digital product") }
      let(:purchase) do
        create(
          :purchase,
          link: product,
          seller:,
          price_cents: 14_99,
          created_at: DateTime.parse("January 1, 2023")
        )
      end

      context "when there are no recommended products" do
        it "doesn't include recommended products section" do
          mail = CustomerMailer.receipt(purchase.id)
          expect(mail.body.sanitized).not_to have_text("Customers who bought this item also bought")
        end
      end

      context "when there are recommended products" do
        let(:recommendable_product) do
          create(:product, :recommendable, name: "Recommended product", price_cents: 9_99)
        end
        let!(:affiliate) do
          create(
            :direct_affiliate,
            seller: recommendable_product.user,
            products: [recommendable_product], affiliate_user: create(:user)
          )
        end

        before do
          purchase.update!(purchaser: create(:user))
          seller.update!(recommendation_type: User::RecommendationType::GUMROAD_AFFILIATES_PRODUCTS)
        end

        it "includes recommended products section" do
          expect(RecommendedProductsService).to receive(:fetch).with(
            {
              model: "sales",
              ids: [purchase.link.id],
              exclude_ids: [purchase.link.id],
              number_of_results: RecommendedProducts::BaseService::NUMBER_OF_RESULTS,
              user_ids: nil,
            }
          ).and_return(Link.where(id: [recommendable_product.id]))

          mail = CustomerMailer.receipt(purchase.id)

          expect(mail.body.sanitized).to have_text("Customers who bought this item also bought")
          expect(mail.body.sanitized).to have_text("$9.99")
        end
      end
    end

    context "with membership purchase" do
      let(:product) { create(:membership_product) }
      let(:purchase) do
        create(
          :membership_purchase,
          link: product,
          price_cents: 1998,
          created_at: DateTime.parse("January 1, 2023"),
        )
      end

      before do
        purchase.create_url_redirect!
      end

      it "has the view content link in the receipt for a membership product" do
        mail = CustomerMailer.receipt(purchase.id)
        expect(mail.body.sanitized).to match("View content")
      end

      context "when is original purchase" do
        before do
          purchase.update!(is_original_subscription_purchase: true)
        end

        it "has the view content button and details" do
          mail = CustomerMailer.receipt(purchase.id)
          expect(mail.body.sanitized).to match("View content")
        end
      end

      it "renders subscription receipt" do
        mail = CustomerMailer.receipt(purchase.id)

        expect(mail.body.sanitized).to have_text(
          "All charges are processed in United States Dollars. " +
          "Your bank or financial institution may apply their own fees for currency conversion."
        )
        expect(mail.body.sanitized).to have_text("The charge will be listed as GUMRD.COM* on your credit card statement.")
        expect(mail.body.sanitized).to have_text("Today's payment The Works of Edgar Gumstein $19.98 Generate invoice")
        expect(mail.body.encoded).to have_link("Generate invoice")
        expect(mail.body.sanitized).to have_text("Upcoming payment The Works of Edgar Gumstein $19.98 on Feb 1, 2023")
        expect(mail.body.sanitized).to have_text("Payment method VISA *4062")
        expect(mail.body.encoded).to have_link("View content")

        expect(mail.body.sanitized).to have_text("You will be charged once a month. If you would like to manage your membership you can visit subscription settings.")
        expect(mail.body.encoded).to have_link("Generate invoice")
      end

      context "with tax charge" do
        before do
          purchase.update!(was_purchase_taxable: true, tax_cents: 254, price_cents: 1_744, displayed_price_cents: 1_744)
        end

        it "renders tax amount" do
          mail = CustomerMailer.receipt(purchase.id)

          expect(mail.body.sanitized).to have_text("Today's payment The Works of Edgar Gumstein $17.44")
          expect(mail.body.sanitized).to have_text("Sales tax (included) $2.54")
          expect(mail.body.sanitized).to have_text("Amount paid $19.98")
          expect(mail.body.encoded).to have_link("Generate invoice")
          expect(mail.body.sanitized).to have_text("Upcoming payment The Works of Edgar Gumstein $19.98 on Feb 1, 2023")
          expect(mail.body.sanitized).to have_text("Payment method VISA *4062")
        end

        context "with shipping charge" do
          before do
            purchase.update!(
              shipping_cents: 499,
              total_transaction_cents: purchase.total_transaction_cents + 499
            )
          end

          it "renders shipping amount" do
            mail = CustomerMailer.receipt(purchase.id)

            expect(mail.body.sanitized).to have_text("Today's payment The Works of Edgar Gumstein $17.44")
            expect(mail.body.sanitized).to have_text("Shipping $4.99")
            expect(mail.body.sanitized).to have_text("Sales tax (included) $2.54")
            expect(mail.body.sanitized).to have_text("Amount paid $24.97")
            expect(mail.body.encoded).to have_link("Generate invoice")
            expect(mail.body.sanitized).to have_text("The Works of Edgar Gumstein $24.97 on Feb 1, 2023")
          end

          context "when purchase is in EUR" do
            before do
              purchase.link.default_price.update!(currency: Currency::EUR)
              purchase.link.update!(price_currency_type: Currency::EUR)
              purchase.update!(
                displayed_price_currency_type: Currency::EUR,
                rate_converted_to_usd: 1.07,
                displayed_price_cents: 1_866 # 17.44 * 1.07
              )
            end

            it "renders correct amounts" do
              mail = CustomerMailer.receipt(purchase.id)

              expect(mail.body.sanitized).to have_text("Today's payment The Works of Edgar Gumstein $17.44")
              expect(mail.body.sanitized).to have_text("Shipping $4.99")
              expect(mail.body.sanitized).to have_text("Sales tax (included) $2.54")
              expect(mail.body.sanitized).to have_text("Amount paid $24.97")
              expect(mail.body.encoded).to have_link("Generate invoice")
              expect(mail.body.sanitized).to have_text("The Works of Edgar Gumstein €26.72 on Feb 1, 2023") # 24.97 * 1.07
            end
          end
        end
      end

      context "with free trial membership purchase" do
        let(:purchase) do
          create(
            :free_trial_membership_purchase,
            price_cents: 3_00,
            created_at: Date.new(2023, 1, 1),
          )
        end

        it "renders payment details" do
          purchase.subscription.update!(free_trial_ends_at: Date.new(2023, 1, 8))
          mail = CustomerMailer.receipt(purchase.id)

          expect(mail.body.sanitized).to have_text("Your free trial has begun!")
          expect(mail.body.sanitized).to have_text("Today's payment The Works of Edgar Gumstein $0")
          expect(mail.body.sanitized).to have_text("Upcoming payment The Works of Edgar Gumstein $3 on Jan 8, 2023")
          expect(mail.body.encoded).not_to have_link("Generate invoice")
        end
      end

      context "when the purchase has fixed length" do
        context "when there is at least one more remaining charge" do
          before do
            purchase.subscription.update!(charge_occurrence_count: 2)
          end

          it "renders upcoming payment information" do
            mail = CustomerMailer.receipt(purchase.id)

            expect(mail.body.sanitized).to have_text("Upcoming payment The Works of Edgar Gumstein: 2 of 2 $19.98 on Feb 1, 2023")
          end
        end

        context "when there are no more remaining charges" do
          before do
            purchase.subscription.update!(charge_occurrence_count: 1)
          end

          it "does not render upcoming payment information" do
            mail = CustomerMailer.receipt(purchase.id)

            expect(mail.body.sanitized).not_to have_text("Upcoming payment")
          end
        end
      end

      context "when the product is licensed" do
        let!(:license) { create(:license, purchase:, link: purchase.link) }

        before do
          purchase.link.update!(is_licensed: true)
        end

        it "includes license details" do
          mail = CustomerMailer.receipt(purchase.id)
          expect(mail.body.sanitized).to include license.serial
        end

        context "when is not the original purchase" do
          let(:recurring_membership_purchase) { create(:recurring_membership_purchase, :with_license) }

          before do
            recurring_membership_purchase.create_url_redirect!
          end

          it "does not include license details" do
            mail = CustomerMailer.receipt(recurring_membership_purchase.id)

            expect(mail.body.sanitized).not_to include license.serial
          end
        end

        context "when is a multi-seat license" do
          before do
            purchase.update!(
              is_multiseat_license: true,
              quantity: 2
            )
          end

          it "includes number of seats" do
            mail = CustomerMailer.receipt(purchase.id)
            expect(mail.body.sanitized).to have_text "Number of seats 2"
          end
        end
      end

      context "when the purchase has custom fields" do
        before do
          purchase.purchase_custom_fields << [
            build(:purchase_custom_field, name: "Field 1", value: "FIELD1_VALUE"),
            build(:purchase_custom_field, name: "Field 2", value: "FIELD2_VALUE"),
          ]
        end

        it "includes custom fields details" do
          mail = CustomerMailer.receipt(purchase.id)
          expect(mail.body.sanitized).to have_text "Field 1 FIELD1_VALUE"
          expect(mail.body.sanitized).to have_text "Field 2 FIELD2_VALUE"
        end
      end

      context "when the product requires shipping" do
        let(:shipping_details) do
          {
            full_name: "Edgar Gumstein",
            street_address: "123 Gum Road",
            country: "United States",
            state: "CA",
            zip_code: "94107",
            city: "San Francisco",
          }
        end

        before do
          purchase.link.update!(require_shipping: true)
          purchase.update!(**shipping_details)
        end

        it "includes shipping details" do
          mail = CustomerMailer.receipt(purchase.id)
          expect(mail.body.sanitized).to include "Shipping info"
          expect(mail.body.sanitized).to include "Shipping address"
          expect(mail.body.sanitized).to include "Edgar Gumstein"
          expect(mail.body.sanitized).to include "123 Gum Road"
          expect(mail.body.sanitized).to include "San Francisco, CA 94107"
          expect(mail.body.sanitized).to include "United States"
        end
      end
    end

    it "shows the custom view content text in the receipt" do
      product = create(:product_with_pdf_file)
      product.save_custom_view_content_button_text("Custom Text")
      purchase = create(:purchase, link: product, purchaser: @user)
      create(:url_redirect, purchase:)
      mail = CustomerMailer.receipt(purchase.id)
      expect(mail.body.sanitized).to match("Custom Text")
    end

    it "shows the view content link in the receipt for a product having rich content" do
      product = create(:product)
      purchase = create(:purchase, link: product, purchaser: @user)
      create(:url_redirect, purchase:)
      mail = CustomerMailer.receipt(purchase.id)

      expect(mail.body.sanitized).to include("View content")
    end

    it "discloses sales tax when it was taxed" do
      user = create(:user)
      link = create(:product, user:)
      zip_tax_rate = create(:zip_tax_rate)
      purchase = create(:purchase, link:, seller: link.user, zip_tax_rate:)
      purchase.was_purchase_taxable = true
      purchase.tax_cents = 1_50
      purchase.save
      mail = CustomerMailer.receipt(purchase.id)
      expect(mail.body.sanitized).to match("Sales tax")
    end

    it "does not render tax or total fields if purchas was not taxed" do
      user = create(:user)
      link = create(:product, user:)
      purchase = create(:purchase, link:, seller: link.user)
      purchase.was_purchase_taxable = false
      purchase.save

      mail = CustomerMailer.receipt(purchase.id)
      expect(mail.body.sanitized).to_not match("Sales tax")
      expect(mail.body.sanitized).to_not match("Order total")
    end

    it "correctly renders variants" do
      user = create(:user)
      link = create(:product, user:)
      purchase = create(:purchase, link:, seller: link.user)
      category = create(:variant_category, title: "sizes", link:)
      variant = create(:variant, name: "small", price_difference_cents: 300, variant_category: category)
      category2 = create(:variant_category, title: "colors", link:)
      variant2 = create(:variant, name: "red", price_difference_cents: 300, variant_category: category2)
      purchase.variant_attributes << variant
      purchase.variant_attributes << variant2
      mail = CustomerMailer.receipt(purchase.id)
      expect(mail.body.sanitized).to match("small, red")
    end

    context "when is a test purchase" do
      let(:seller) { create(:named_seller) }
      let(:product) { create(:product, user: seller, name: "Test product") }
      let(:purchase) { create(:purchase, link: product, seller:, purchaser: seller) }

      it "renders the receipt" do
        mail = CustomerMailer.receipt(purchase.id)
        expect(mail.body.sanitized).to match(product.name)
        expect(mail.body.sanitized.include?("This was a test purchase — you have not been charged")).to be(true)
        expect(mail.subject).to eq "You bought #{product.name}!"
      end
    end

    describe "shipping display" do
      describe "product with shipping" do
        let(:product) { create(:physical_product) }
        let(:purchase) { create(:physical_purchase, link: product) }

        before do
          purchase.shipping_cents = 20_00
          purchase.save!
        end

        it "shows the shipping line item in the receipt" do
          mail = CustomerMailer.receipt(purchase.id)
          expect(mail.body.sanitized).to match("Shipping")
        end
      end

      describe "product without shipping" do
        let(:product) { create(:product) }
        let(:purchase) { create(:purchase, link: product) }

        it "does not show the shipping line item in the receipt" do
          mail = CustomerMailer.receipt(purchase.id)
          expect(mail.body.sanitized).to_not match("Shipping")
        end
      end
    end

    context "when the purchase has a refund policy" do
      let(:purchase) { create(:purchase) }

      before do
        purchase.create_purchase_refund_policy!(
          title: "Refund policy",
          fine_print: "This is the fine print."
        )
      end

      it "includes the refund policy" do
        mail = CustomerMailer.receipt(purchase.id)

        expect(mail.body.sanitized).to include("Refund policy")
        expect(mail.body.sanitized).to include("This is the fine print.")
      end
    end

    describe "subscription with limited duration discount" do
      let(:purchase) do
        create(
          :membership_purchase,
          price_cents: 500,
          created_at: DateTime.parse("January 1, 2023"),
        )
      end

      before do
        purchase.create_purchase_offer_code_discount(
          offer_code: create(:offer_code, user: purchase.seller, products: [purchase.link]),
          offer_code_amount: 100,
          offer_code_is_percent: false,
          pre_discount_minimum_price_cents: 600,
          duration_in_billing_cycles: 1
        )
        purchase.create_url_redirect!
      end

      context "when the discount's duration has elapsed" do
        it "includes the correct payment amounts" do
          mail = CustomerMailer.receipt(purchase.id)
          expect(mail.body.sanitized).to have_text("Today's payment")
          expect(mail.body.sanitized).to have_text("The Works of Edgar Gumstein $5")
          expect(mail.body.sanitized).to have_text("Upcoming payment")
          expect(mail.body.sanitized).to have_text("The Works of Edgar Gumstein $6 on Feb 1, 2023")
        end

        context "when the purchase includes tax" do
          before do
            allow_any_instance_of(SalesTaxCalculator).to receive_message_chain(:calculate, :tax_cents).and_return(100)
          end

          it "includes the correct payment amounts" do
            mail = CustomerMailer.receipt(purchase.id)
            expect(mail.body.sanitized).to have_text("Today's payment")
            expect(mail.body.sanitized).to have_text("The Works of Edgar Gumstein $5")
            expect(mail.body.sanitized).to have_text("Upcoming payment")
            expect(mail.body.sanitized).to have_text("The Works of Edgar Gumstein $7 on Feb 1, 2023")
          end
        end
      end

      context "when the discount's duration has not elapsed" do
        before do
          purchase.purchase_offer_code_discount.update!(duration_in_billing_cycles: 2)
        end

        it "includes the correct payment amounts" do
          mail = CustomerMailer.receipt(purchase.id)
          expect(mail.body.sanitized).to have_text("Today's payment")
          expect(mail.body.sanitized).to have_text("The Works of Edgar Gumstein $5")
          expect(mail.body.sanitized).to have_text("Upcoming payment")
          expect(mail.body.sanitized).to have_text("The Works of Edgar Gumstein $5 on Feb 1, 2023")
        end
      end
    end

    context "commission deposit purchase", :vcr do
      let(:purchase) { create(:commission_deposit_purchase) }

      before { purchase.create_artifacts_and_send_receipt! }

      it "includes the correct payment amounts" do
        mail = CustomerMailer.receipt(purchase.id)
        expect(mail.body.sanitized).to have_text("Product price $2")
        expect(mail.body.sanitized).to have_text("Today's payment")
        expect(mail.body.sanitized).to have_text("The Works of Edgar Gumstein $1")
        expect(mail.body.sanitized).to have_text("Upcoming payment")
        expect(mail.body.sanitized).to have_text("The Works of Edgar Gumstein $1 on completion")
      end
    end

    context "commission completion purchase", :vcr do
      let(:commission) { create(:commission) }

      before do
        commission.create_completion_purchase!
        commission.deposit_purchase.create_url_redirect!
      end

      it "includes the correct subject and view content link" do
        mail = CustomerMailer.receipt(commission.completion_purchase.id)
        expect(mail.subject).to eq("The Works of Edgar Gumstein is ready for download!")
        expect(mail.body.encoded).to have_link("View content", href: commission.deposit_purchase.url_redirect.download_page_url)
      end
    end

    context "purchase with a tip" do
      let(:purchase) { create(:purchase, price_cents: 1000) }

      before { purchase.create_tip!(value_cents: 500) }

      it "includes the tip info in the receipt" do
        mail = CustomerMailer.receipt(purchase.id)

        expect(mail.body.sanitized).to have_text("Product price $5")
        expect(mail.body.sanitized).to have_text("Tip $5")
        expect(mail.body.sanitized).to have_text("The Works of Edgar Gumstein $10")
      end
    end

    context "call purchase" do
      let(:purchase) { create(:call_purchase, variant_attributes: [create(:variant, name: "1 hour")]) }

      before { purchase.create_artifacts_and_send_receipt! }

      it "includes the correct attributes" do
        mail = CustomerMailer.receipt(purchase.id)
        expect(mail.body.sanitized).to include("Call schedule #{purchase.call.formatted_time_range} #{purchase.call.formatted_date_range}")
        expect(mail.body.sanitized).to include("Duration 1 hour")
        expect(mail.body.sanitized).to include("Product price $1")
        expect(mail.body.sanitized).to_not have_text("Variant")
      end
    end

    context "bundle purchase" do
      let(:purchase) { create(:purchase, link: create(:product, :bundle)) }

      before do
        purchase.seller.update!(name: "Seller")
        purchase.create_artifacts_and_send_receipt!
      end

      it "includes information for all of the bundle products" do
        mail = CustomerMailer.receipt(purchase.id)
        expect(mail.body.sanitized).to have_text("Bundle Product 1")
        expect(mail.body.encoded).to have_link("View content", href: purchase.product_purchases.first.url_redirect.download_page_url)
        expect(mail.body.sanitized).to have_text("Bundle Product 2")
        expect(mail.body.encoded).to have_link("View content", href: purchase.product_purchases.second.url_redirect.download_page_url)
        expect(mail.body.sanitized).to have_text("Questions about your products? Contact Seller by replying to this email.")
      end
    end

    context "product_questions_note" do
      let(:purchase) { create(:purchase) }
      subject(:mail) { CustomerMailer.receipt(purchase.id) }

      before do
        purchase.seller.update!(name: "Seller")
        purchase.create_url_redirect!
      end

      it "generates questions note with reply" do
        expect(mail.body.sanitized).to have_text("Questions about your product? Contact Seller by replying to this email.")
      end

      context "when for_email is set to false" do
        subject(:mail) { CustomerMailer.receipt(purchase.id, for_email: false) }

        it "generates questions note with email" do
          expect(mail.body.sanitized).to have_text("Questions about your product? Contact Seller at #{purchase.seller.email}.")
        end
      end
    end

    describe "gift_receiver_receipt" do
      let(:product) { create(:product, name: "Digital product") }
      let(:gift) { create(:gift, gift_note: "Happy birthday!", giftee_email: "giftee@example.com", gifter_email: "gifter@example.com", link: product) }
      let!(:gift_sender_purchase) { create(:purchase, link: product, gift_given: gift, is_gift_sender_purchase: true, email: "gifter@example.com") }
      let(:purchase) { create(:purchase, link: product, gift_received: gift, is_gift_receiver_purchase: true, email: "giftee@example.com") }
      let(:seller) { product.user }

      before do
        purchase.create_url_redirect!
        seller.update!(name: "Seller")
      end

      subject(:mail) do
        CustomerMailer.receipt(purchase.id)
      end

      it "renders the headers for a receipt" do
        expect(mail.subject).to eq("gifter@example.com bought Digital product for you!")
        expect(mail.to).to eq(["giftee@example.com"])
        expect(mail[:from].value).to eq("Seller <noreply@#{CUSTOMERS_MAIL_DOMAIN}>")
        expect(mail[:reply_to].value).to eq(seller.email)
      end

      it "renders the body" do
        expect(mail.body.sanitized).to have_text("Hi! gifter@example.com bought this as a gift for you. We hope you like it!")
        expect(mail.body.sanitized).to have_text("Happy birthday!")
        expect(mail.body.sanitized).to match(purchase.link_name)
      end

      context "when the purchase includes shipping" do
        let(:product) { create(:physical_product) }
        let(:gift_sender_purchase) { create(:physical_purchase, link: product, gift_given: gift, is_gift_sender_purchase: true, email: "gifter@example.com") }
        let(:purchase) do
          create(
            :physical_purchase,
            link: product,
            gift_received: gift,
            is_gift_receiver_purchase: true,
            email: "giftee@example.com",
          )
        end

        it "includes the shipping info section" do
          expect(mail.body.sanitized).to have_text("Shipping info")
        end
      end

      context "when the purchase is a membership" do
        let(:product) { create(:membership_product) }
        let(:gift_sender_purchase) { create(:membership_purchase, link: product, gift_given: gift, is_gift_sender_purchase: true, email: "gifter@example.com") }
        let(:purchase) { create(:membership_purchase, link: product, gift_received: gift, is_gift_receiver_purchase: true, email: "giftee@example.com") }

        before do
          allow_any_instance_of(Subscription).to receive(:true_original_purchase).and_return(gift_sender_purchase)
        end

        it "includes the manage membership link" do
          expect(mail.body.sanitized).to have_text("If you wish to continue your membership, you can visit subscription settings")
        end
      end
    end

    describe "gift sender receipt" do
      let(:seller) { create(:named_seller)  }
      let(:product) { create(:product, name: "Digital product", user: seller) }
      let(:giftee) { create(:user, name: "Giftee", email: "giftee@example.com") }
      let(:gift) { create(:gift, gift_note: "Happy birthday!", giftee_email: giftee.email, gifter_email: "gifter@example.com", link: product) }
      let!(:gift_receiver_purchase) { create(:purchase, link: product, gift_received: gift, is_gift_receiver_purchase: true, purchaser: giftee, email: giftee.email) }
      let(:purchase) { create(:purchase, link: product, gift_given: gift, is_gift_sender_purchase: true, email: "gifter@example.com") }

      subject(:mail) do
        CustomerMailer.receipt(purchase.id)
      end

      it "renders the headers for a receipt" do
        expect(mail.subject).to eq("You bought giftee@example.com Digital product!")
        expect(mail.to).to eq(["gifter@example.com"])
        expect(mail[:from].value).to eq("Seller <noreply@#{CUSTOMERS_MAIL_DOMAIN}>")
        expect(mail[:reply_to].value).to eq(seller.email)
      end

      context "when the recipient email is hidden" do
        before { gift.update!(is_recipient_hidden: true) }

        it "shows the name instead" do
          expect(mail.subject).to eq("You bought Giftee Digital product!")
          expect(mail.body.sanitized).not_to include(gift.giftee_email)
          expect(mail.body.sanitized).to include("Gift sent to Giftee")
        end
      end

      context "when it is a membership purchase" do
        let(:product) { create(:membership_product) }
        let!(:gift_receiver_purchase) { create(:membership_purchase, link: product, gift_received: gift, is_gift_receiver_purchase: true, email: "giftee@example.com") }
        let(:purchase) { create(:membership_purchase, link: product, gift_given: gift, is_gift_sender_purchase: true, email: "gifter@example.com") }

        it "does not includes the manage membership link, only a notice regarding renewal" do
          expect(mail.body.sanitized).to_not have_text("If you would like to manage your membership you can visit subscription settings.")
          expect(mail.body.sanitized).to have_text("Note that giftee@example.com’s membership will not automatically renew.")
        end
      end
    end
  end

  describe "receipt for multi-items" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller, name: "Product One") }
    let(:purchase_one) { create(:purchase, link: product, seller: seller) }
    let(:product_two) { create(:product, user: seller, name: "Product Two") }
    let(:purchase_two) { create(:purchase, link: product_two, seller: seller) }
    let(:charge) { create(:charge, purchases: [purchase_one, purchase_two], seller: seller) }
    let(:order) { charge.order }

    before do
      charge.order.purchases << purchase_one
      charge.order.purchases << purchase_two
    end

    let(:mailer) do
      CustomerMailer.receipt(nil, charge.id)
    end

    it "processes the mailer and generates the correct headers" do
      expect(mailer.subject).to eq("You bought Product One and Product Two")
      expect(mailer.to).to eq([order.email])
      expect(mailer[:from].value).to eq("#{charge.seller.name} <noreply@#{CUSTOMERS_MAIL_DOMAIN}>")
      expect(mailer[:reply_to].value).to eq(charge.seller.email)
    end

    context "products have the same support emails" do
      let(:product_support_email) { "product_support_email@example.com" }
      let(:product) { create(:product, user: seller, name: "Product One", support_email: product_support_email) }
      let(:product_two) { create(:product, user: seller, name: "Product Two", support_email: product_support_email) }

      it "use the product support email" do
        expect(mailer[:reply_to].value).to eq(product_support_email)
      end
    end

    context "when products have different support emails" do
      let(:product) { create(:product, user: seller, name: "Product One", support_email: "reply_to@example.com") }
      let(:product_two) { create(:product, user: seller, name: "Product Two", support_email: nil) }

      it "uses seller's default email" do
        expect(mailer[:reply_to].value).to eq(charge.seller.support_or_form_email)
      end
    end
  end

  describe ".abandoned_cart_preview" do
    let(:buyer) { create(:named_user) }
    let(:seller) { create(:named_seller, name: "John Doe") }
    let!(:payment_completed) { create(:payment_completed, user: seller) }
    let(:workflow) { create(:abandoned_cart_workflow, seller:) }
    let(:installment) { workflow.installments.first }
    let!(:another_seller_product) { create(:product, name: "Another seller product") }
    let!(:products) { create_list(:product, 4, user: seller) { |product, i| product.update!(name: "Product #{i + 1}") } }
    subject(:mail) { CustomerMailer.abandoned_cart_preview(seller.id, installment.id) }

    it "renders the abandoned cart email" do
      expect(mail.to).to eq [seller.email]
      expect(mail.subject).to eq("You left something in your cart")

      sanitized_body = mail.body.sanitized
      expect(sanitized_body).to have_text("You left something in your cart")
      expect(sanitized_body).to have_text("When you're ready to buy, complete checking out.")
      expect(sanitized_body).to have_text("Product 1")
      expect(sanitized_body).to have_text("Product 2")
      expect(sanitized_body).to have_text("Product 3")
      expect(sanitized_body).to_not have_text("Product 4")
      expect(sanitized_body).to_not have_text("Another seller product")
      expect(mail.body).to have_link("John Doe", href: "http://seller.test.gumroad.com:31337", exact: true, count: 3)
      expect(mail.body).to have_link("and 1 more product", href: checkout_index_url(host: UrlService.domain_with_protocol))
      expect(sanitized_body).to have_text("Thanks!")
      expect(mail.body).to have_link("Complete checkout", href: checkout_index_url(host: UrlService.domain_with_protocol))
    end
  end

  describe ".abandoned_cart" do
    let(:seller1) { create(:user, name: "John Doe", username: "johndoe") }
    let(:seller2) { create(:user, name: "John Smith", username: "johnsmith") }
    let!(:seller1_payment) { create(:payment_completed, user: seller1) }
    let!(:seller2_payment) { create(:payment_completed, user: seller2) }
    let!(:seller1_workflow) { create(:abandoned_cart_workflow, seller: seller1, published_at: 1.day.ago) }
    let(:seller1_workflow_installment) { seller1_workflow.installments.first }
    let!(:seller2_workflow) { create(:abandoned_cart_workflow, seller: seller2, published_at: 1.day.ago) }
    let(:seller2_workflow_installment) { seller2_workflow.installments.first }
    let!(:seller1_products) { create_list(:product, 4, user: seller1) { |product, i| product.update!(name: "S1 Product #{i + 1}") } }
    let!(:seller2_products) { create_list(:product, 4, user: seller2) { |product, i| product.update!(name: "S2 Product #{i + 1}") } }

    context "when the cart is missing user_id" do
      let(:cart) { create(:cart, user: nil, email: "guest@example.com") }
      let!(:cart_product) { create(:cart_product, cart: cart, product: seller1.products.first) }

      before do
        cart.update!(updated_at: 2.days.ago)
      end

      it "sends an email" do
        expect do
          mail = CustomerMailer.abandoned_cart(cart.id, { seller1_workflow.id => [seller1.products.first.id] }.stringify_keys)
          expect(mail.to).to eq(["guest@example.com"])
          expect(mail.from).to eq(["noreply@#{CUSTOMERS_MAIL_DOMAIN}"])
          expect(mail.subject).to eq("You left something in your cart")
          expect(mail.body.sanitized).to have_text("You left something in your cart")
          expect(mail.body.sanitized).to have_text("S1 Product 1")
          expect(mail.body.sanitized).to_not have_text("S1 Product 2")
          expect(mail.body.sanitized).to have_text("Thanks!")
          expect(mail.body).to have_link("Complete checkout", href: checkout_index_url(host: UrlService.domain_with_protocol, cart_id: cart.external_id))
        end.to change { SentAbandonedCartEmail.count }.by(1)
      end

      it "does not send an email if the email is blank" do
        cart.update!(email: nil)
        mail = CustomerMailer.abandoned_cart(cart.id, { seller1_workflow.id => [seller1.products.first.id] }.stringify_keys)
        expect(mail.message).to be_a(ActionMailer::Base::NullMail)
      end
    end

    context "when the cart is not abandoned" do
      let(:cart) { create(:cart) }

      it "does not send an email" do
        mail = CustomerMailer.abandoned_cart(cart.id, { seller1_workflow.id => [seller1.products.first.id] }.stringify_keys)
        expect(mail.message).to be_a(ActionMailer::Base::NullMail)
      end
    end

    context "when the cart is abandoned" do
      let(:cart) { create(:cart) }

      before do
        create(:cart_product, cart: cart, product: seller1.products.first)
        cart.update!(updated_at: 25.hours.ago)
      end

      context "when the provided workflow is not published" do
        before do
          seller1_workflow.unpublish!
        end

        it "does not send an email" do
          mail = CustomerMailer.abandoned_cart(cart.id, { seller1_workflow.id => [seller1.products.first.id] }.stringify_keys)
          expect(mail.message).to be_a(ActionMailer::Base::NullMail)
        end
      end

      context "when the provided workflow is not of 'abaonded_cart' type" do
        before do
          seller1_workflow.update!(workflow_type: Workflow::SELLER_TYPE)
        end

        it "does not send an email" do
          mail = CustomerMailer.abandoned_cart(cart.id, { seller1_workflow.id => [seller1.products.first.id] }.stringify_keys)
          expect(mail.message).to be_a(ActionMailer::Base::NullMail)
        end
      end

      context "when the provided workflow does not have matching abandoned products" do
        before do
          seller1_workflow.update!(not_bought_products: [seller1.products.first.unique_permalink])
        end

        it "does not send an email" do
          mail = CustomerMailer.abandoned_cart(cart.id, { seller1_workflow.id => [seller1.products.first.id] }.stringify_keys)
          expect(mail.message).to be_a(ActionMailer::Base::NullMail)
        end
      end

      context "when the provided workflow is published and has matching abandoned products" do
        it "sends an email" do
          expect do
            seller1_workflow_installment.update!(name: "Uh oh, you left something in your cart!")
            mail = CustomerMailer.abandoned_cart(cart.id, { seller1_workflow.id => [seller1.products.first.id] }.stringify_keys)
            expect(mail.to).to eq [cart.user.email]
            expect(mail.from).to eq ["noreply@#{CUSTOMERS_MAIL_DOMAIN}"]
            expect(mail.subject).to eq("Uh oh, you left something in your cart!")
            expect(mail.body.sanitized).to have_text("Uh oh, you left something in your cart!")
            expect(mail.body.sanitized).to have_text("S1 Product 1")
            expect(mail.body.sanitized).to_not have_text("S1 Product 2")
            expect(mail.body.sanitized).to_not have_text("S2 Product 1")
            expect(mail.body.sanitized).to have_text("Thanks!")
            expect(mail.body).to have_link("Complete checkout", href: checkout_index_url(host: UrlService.domain_with_protocol, cart_id: cart.external_id))
          end.to change { SentAbandonedCartEmail.count }.by(1)

          expect(SentAbandonedCartEmail.last).to have_attributes(cart_id: cart.id, installment_id: seller1_workflow_installment.id)
        end

        context "when more than three products are matched" do
          it "renders the first three products and a link to the rest" do
            mail = CustomerMailer.abandoned_cart(cart.id, { seller1_workflow.id => seller1.products.pluck(:id) }.stringify_keys)
            expect(mail.body.sanitized).to have_text("S1 Product 1")
            expect(mail.body.sanitized).to have_text("S1 Product 2")
            expect(mail.body.sanitized).to have_text("S1 Product 3")
            expect(mail.body).to have_link("and 1 more product", href: checkout_index_url(host: UrlService.domain_with_protocol, cart_id: cart.external_id))
            expect(mail.body.sanitized).to_not have_text("S1 Product 4")
          end
        end

        context "when 'is_preview' is true" do
          it "does not create SentAbandonedCartEmail records" do
            expect do
              mail = CustomerMailer.abandoned_cart(cart.id, { seller1_workflow.id => [seller1.products.first.id] }.stringify_keys, true)
              expect(mail.to).to eq [cart.user.email]
            end.not_to change { SentAbandonedCartEmail.count }
          end
        end
      end

      context "when multiple workflows are provided" do
        it "sends a combined email" do
          expect do
            seller1_workflow_installment.update!(name: "Uh oh, you left something in your cart!")
            seller2_workflow_installment.update!(name: "Hurry up and complete your purchase!")

            mail = CustomerMailer.abandoned_cart(cart.id, {
              seller1_workflow.id => seller1.products.pluck(:id).first(2),
              seller2_workflow.id => seller2.products.pluck(:id),
            }.stringify_keys)
            expect(mail.to).to eq [cart.user.email]
            expect(mail.from).to eq ["noreply@#{CUSTOMERS_MAIL_DOMAIN}"]
            expect(mail.subject).to eq("You left something in your cart")
            expect(mail.body.sanitized).to have_text("Uh oh, you left something in your cart!")
            expect(mail.body.sanitized).to have_text("S1 Product 1")
            expect(mail.body.sanitized).to have_text("S1 Product 2")
            expect(mail.body.sanitized).to_not have_text("S1 Product 3")
            expect(mail.body.sanitized).to_not have_text("S1 Product 4")
            expect(mail.body).to have_link("John Doe", href: "http://johndoe.test.gumroad.com:31337", exact: true, count: 2)
            expect(mail.body.sanitized).to have_text("Hurry up and complete your purchase!")
            expect(mail.body.sanitized).to have_text("S2 Product 1")
            expect(mail.body.sanitized).to have_text("S2 Product 2")
            expect(mail.body.sanitized).to have_text("S2 Product 3")
            expect(mail.body.sanitized).to_not have_text("S2 Product 4")
            expect(mail.body).to have_link("John Smith", href: "http://johnsmith.test.gumroad.com:31337", exact: true, count: 3)
            expect(mail.body).to have_link("and 1 more product", href: checkout_index_url(host: UrlService.domain_with_protocol, cart_id: cart.external_id), count: 1)
            expect(mail.body).to have_link("Complete checkout", href: checkout_index_url(host: UrlService.domain_with_protocol, cart_id: cart.external_id), count: 2)
          end.to change { SentAbandonedCartEmail.count }.by(2)

          expect(SentAbandonedCartEmail.pluck(:cart_id, :installment_id)).to match_array([
                                                                                           [cart.id, seller1_workflow_installment.id],
                                                                                           [cart.id, seller2_workflow_installment.id],
                                                                                         ])
        end
      end
    end
  end

  describe "#review_response" do
    let!(:seller) { create(:named_seller, name: "Olivander") }
    let!(:product) { create(:product, user: seller) }
    let!(:buyer) { create(:named_user, name: "Harry") }
    let!(:purchase) { create(:purchase, link: product, purchaser: buyer, email: buyer.email) }
    let!(:review) { create(:product_review,  purchase:, rating: 4, message: "Here is a review.") }
    let!(:response) { create(:product_review_response, product_review: review, message: "Here is a response.", user: create(:user, name: "Clerk")) }

    it "renders the review response email" do
      mail = CustomerMailer.review_response(response)

      expect(mail.to).to contain_exactly(buyer.email)
      expect(mail.subject).to eq("Olivander responded to your review")
      expect(mail.body).to have_selector("[aria-label='4 stars']")
      expect(mail.body).to have_selector("img[src='#{ActionController::Base.helpers.asset_path("email/solid-star.png")}']", count: 4)
      expect(mail.body).to have_selector("img[src='#{ActionController::Base.helpers.asset_path("email/outline-star.png")}']", count: 1)
      expect(mail.body).to have_selector(".content p", text: "Here is a review.")
      expect(mail.body).to have_selector(".content .byline", text: "Harry")
      expect(mail.body).to have_selector(".content.response p", text: "Here is a response.")
      expect(mail.body).to have_selector(".content.response .byline", text: "Olivander")
      expect(mail.body).to have_link("View product", href: product.long_url)
    end
  end

  describe ".upcoming_call_reminder" do
    let(:call) { create(:call) }

    before do
      call.purchase.update!(variant_attributes: [create(:variant, name: "1 hour")])
      call.purchase.seller.update!(name: "Phone Man")
      call.purchase.create_url_redirect!
    end

    it "includes details about the upcoming call" do
      mail = CustomerMailer.upcoming_call_reminder(call.id)
      expect(mail.subject).to eq("Your scheduled call with Phone Man is tomorrow!")

      expect(mail.body.encoded).to have_text("Your scheduled call with Phone Man is tomorrow!")
      expect(mail.body.encoded).to have_text("Phone Man")
      expect(mail.body.encoded).to have_link("View content", href: call.purchase.url_redirect.download_page_url)
      expect(mail.body.sanitized).to have_text("Call schedule #{call.formatted_time_range} #{call.formatted_date_range}")
      expect(mail.body.sanitized).to have_text("Duration 1 hour")
      expect(mail.body.sanitized).to have_text("Product price $1")
    end
  end

  describe "#subscription_restarted" do
    context "memberships" do
      let(:purchase) { create(:membership_purchase) }

      it "sends an email" do
        mail = CustomerMailer.subscription_restarted(purchase.subscription.id)
        expect(mail.subject).to eq("Your subscription has been restarted.")
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "sends an email" do
        mail = CustomerMailer.subscription_restarted(subscription.id)
        expect(mail.subject).to eq("Your installment plan has been restarted.")
      end
    end
  end

  describe "#subscription_magic_link" do
    let(:purchase) { create(:membership_purchase) }
    let(:subscription) { create(:subscription, original_purchase: purchase) }

    it "sends an email" do
      mail = CustomerMailer.subscription_magic_link(subscription.id, "test@example.com")
      expect(mail.to).to eq(["test@example.com"])
      expect(mail.subject).to eq("Magic Link")
    end
  end

  describe "#paypal_purchase_failed" do
    let(:purchase) { create(:membership_purchase) }

    it "sends an email" do
      mail = CustomerMailer.paypal_purchase_failed(purchase.id)
      expect(mail.to).to eq([purchase.email])
      expect(mail.subject).to eq("Your purchase with PayPal failed.")
    end
  end

  describe "#grouped_receipt" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:purchases) { create_list(:purchase, 2, link: product, seller:) }

    it "sends a grouped receipt email" do
      mail = CustomerMailer.grouped_receipt(purchases.map(&:id))
      expect(mail.to).to eq([purchases.last.email])
      expect(mail.subject).to eq("Receipts for Purchases")
    end
  end

  describe "#refund" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product, seller:) }

    it "sends a refund email" do
      mail = CustomerMailer.refund("test@example.com", product.id, purchase.id)
      expect(mail.to).to eq(["test@example.com"])
      expect(mail.subject).to eq("You have been refunded.")
    end
  end

  describe "#partial_refund" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product, seller:) }

    it "sends a partial refund email" do
      mail = CustomerMailer.partial_refund("test@example.com", product.id, purchase.id, 500, "partially")
      expect(mail.to).to eq(["test@example.com"])
      expect(mail.subject).to eq("You have been partially refunded.")
      expect(mail.body.encoded).to include("$5")
    end
  end

  describe "#send_to_kindle" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product_with_pdf_file, user: seller) }
    let(:product_file) { product.product_files.first }

    before do
      allow_any_instance_of(Aws::S3::Object).to receive(:download_file) do |_, path|
        File.write(path, "test content")
      end
    end

    it "sends a kindle email" do
      mail = CustomerMailer.send_to_kindle("kindle@kindle.com", product_file.id)
      expect(mail.to).to eq(["kindle@kindle.com"])
      expect(mail.subject).to eq("convert")
      expect(mail.attachments.first.filename).to eq(product_file.s3_filename)
    end
  end
end
