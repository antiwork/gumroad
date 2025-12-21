# frozen_string_literal: true

require "shared_examples/customer_drawer_missed_posts_context"

describe CustomerPresenter do
  let(:seller) { create(:named_seller) }

  describe "#missed_posts" do
    let(:product) { create(:product, user: seller) }
    let!(:post1) { create(:installment, link: product, published_at: Time.current, name: "Post 1") }
    let!(:post2) { create(:installment, link: product, published_at: Time.current, name: "Post 2") }
    let!(:post3) { create(:installment, link: product, published_at: Time.current, name: "Post 3") }
    let!(:post4) { create(:installment, link: product, name: "Post 4") }
    let(:purchase) { create(:purchase, link: product) }

    before do
      create(:creator_contacting_customers_email_info_delivered, installment: post1, purchase:)
    end

    it "returns the correct props" do
      expect(CustomersService).to receive(:find_missed_posts_for).with(purchase:, workflow_id: nil).and_call_original

      expect(described_class.new(purchase:).missed_posts).to eq(
        [
          {
            id: post2.external_id,
            name: "Post 2",
            url: post2.full_url,
            published_at: post2.published_at,
          },
          {
            id: post3.external_id,
            name: "Post 3",
            url: post3.full_url,
            published_at: post3.published_at,
          },
        ]
      )
    end

    it "passes workflow_id to service when provided" do
      workflow_id = "workflow-123"
      expect(CustomersService).to receive(:find_missed_posts_for).with(purchase:, workflow_id:).and_call_original

      described_class.new(purchase:).missed_posts(workflow_id:)
    end

    it "only returns installments, not receipts" do
      create(:customer_email_info_opened, purchase:)

      result = described_class.new(purchase:).missed_posts

      expect(result).to be_an(Array)
      expect(result.all? { |item| item.key?(:published_at) }).to be true
      expect(result.none? { |item| item[:type] == "receipt" }).to be true
    end
  end

  describe "#customer" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller, name: "Product", price_cents: 100, is_physical: true, require_shipping: true) }
    let(:membership) { create(:membership_product_with_preset_tiered_pricing, user: seller, name: "Membership", is_multiseat_license: true, is_licensed: true, native_type: Link::NATIVE_TYPE_MEMBERSHIP) }
    let(:offer_code) { create(:percentage_offer_code, code: "code", products: [membership], amount_percentage: 100) }
    let(:purchase1) { create(:physical_purchase, product_review: product_review1, link: product, variant_attributes: [create(:sku, link: product)], full_name: "Customer 1", email: "customer1@gumroad.com", created_at: 1.day.ago, seller:, was_product_recommended: true, recommended_by: RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION, is_purchasing_power_parity_discounted: true, ip_country: "United States", is_additional_contribution: true, is_bundle_purchase: true, can_contact: false) }
    let(:product_review1) { create(:product_review, rating: 4, message: "This is an amazing product!") }
    let!(:product_review_response) { create(:product_review_response, message: "Thank you!", user: seller, product_review: product_review1) }
    let(:purchase2) { create(:membership_purchase, link: membership, full_name: "Customer 2", email: "customer2@gumroad.com", purchaser: create(:user), seller:, is_original_subscription_purchase: true, offer_code:, is_gift_sender_purchase: true, affiliate: create(:direct_affiliate), is_preorder_authorization: true, preorder: create(:preorder), license: create(:license), chargeback_date: Time.current, card_type: CardType::PAYPAL, created_at: 7.months.ago) }
    let(:pundit_user) { SellerContext.new(user: seller, seller:) }

    before do
      purchase1.create_purchasing_power_parity_info!(factor: 0.5)
      create(:gift, giftee_email: "giftee@gumroad.com", giftee_purchase: create(:purchase), gifter_purchase: purchase2)
      purchase2.reload
      create(:upsell_purchase, purchase: purchase1, upsell: create(:upsell, seller:, product:, cross_sell: true))
      purchase2.subscription.update!(charge_occurrence_count: 2)
      create(:purchase_custom_field, purchase: purchase2, name: "Field 1", value: "Value")
      create(:purchase_custom_field, purchase: purchase2, name: "Field 2", value: false, type: CustomField::TYPE_CHECKBOX)
      create(:tip, purchase: purchase1, value_cents: 100)
    end

    it "returns the correct props for each customer" do
      allow(purchase1).to receive(:transaction_url_for_seller).and_return("https://google.com")
      allow(purchase1).to receive(:stripe_partially_refunded?).and_return(true)
      allow(purchase1).to receive(:stripe_refunded?).and_return(true)
      expect(described_class.new(purchase: purchase1).customer(pundit_user:)).to eq(
        {
          id: purchase1.external_id,
          email: "customer1@gumroad.com",
          giftee_email: nil,
          name: "Customer 1",
          is_bundle_purchase: true,
          can_contact: false,
          is_existing_user: false,
          product: {
            name: "Product",
            permalink: product.unique_permalink,
            native_type: "digital"
          },
          quantity: 1,
          created_at: purchase1.created_at.iso8601,
          price: {
            cents: 100,
            cents_before_offer_code: 100,
            cents_refundable: 100,
            currency_type: "usd",
            recurrence: nil,
            tip_cents: 100,
          },
          discount: nil,
          subscription: nil,
          is_multiseat_license: false,
          upsell: "Upsell",
          referrer: "Gumroad Product Recommendations",
          is_additional_contribution: true,
          ppp: { country: "United States", discount: "50%" },
          is_preorder: false,
          affiliate: nil,
          license: nil,
          shipping: {
            address: purchase1.shipping_information,
            price: "$0",
            tracking: { shipped: false },
          },
          physical: {
            order_number: purchase1.external_id_numeric.to_s,
            sku: purchase1.sku&.custom_name_or_external_id,
          },
          review: {
            rating: 4,
            message: "This is an amazing product!",
            response: {
              message: "Thank you!",
            },
            videos: [],
          },
          call: nil,
          commission: nil,
          custom_fields: [],
          transaction_url_for_seller: "https://google.com",
          is_access_revoked: nil,
          refunded: true,
          partially_refunded: true,
          paypal_refund_expired: false,
          chargedback: false,
          has_options: true,
          option: purchase1.variant_attributes.first.to_option,
          utm_link: nil,
          download_count: nil,
        }
      )

      expect(described_class.new(purchase: purchase2).customer(pundit_user:)).to eq(
        {
          id: purchase2.external_id,
          email: "customer2@gumroad.com",
          giftee_email: "giftee@gumroad.com",
          name: "Customer 2",
          is_bundle_purchase: false,
          can_contact: true,
          is_existing_user: true,
          product: {
            name: "Membership",
            permalink: membership.unique_permalink,
            native_type: "membership"
          },
          quantity: 1,
          created_at: purchase2.created_at.iso8601,
          price: {
            cents: 0,
            cents_before_offer_code: 0,
            cents_refundable: 0,
            currency_type: "usd",
            recurrence: "monthly",
            tip_cents: nil,
          },
          discount: { type: "percent", percents: 100, code: "code" },
          subscription: {
            id: purchase2.subscription.external_id,
            status: "alive",
            remaining_charges: 1,
            is_installment_plan: false,
          },
          is_multiseat_license: true,
          upsell: nil,
          referrer: nil,
          is_additional_contribution: false,
          ppp: nil,
          is_preorder: true,
          affiliate: {
            email: purchase2.affiliate.affiliate_user.form_email,
            amount: "$0",
            type: "DirectAffiliate",
          },
          license: {
            id: purchase2.license.external_id,
            enabled: true,
            key: purchase2.license.serial,
          },
          call: nil,
          commission: nil,
          shipping: nil,
          physical: nil,
          review: nil,
          custom_fields: [
            { type: "text", attribute: "Field 1", value: "Value" },
            { type: "text", attribute: "Field 2", value: "false" },
          ],
          transaction_url_for_seller: nil,
          is_access_revoked: nil,
          refunded: false,
          partially_refunded: false,
          paypal_refund_expired: true,
          chargedback: true,
          has_options: true,
          option: purchase2.variant_attributes.first.to_option,
          utm_link: nil,
          download_count: 0,
        }
      )
    end

    context "purchase has a call" do
      let(:call) { create(:call) }

      it "includes the call" do
        expect(described_class.new(purchase: call.purchase).customer(pundit_user:)[:call]).to eq(
          {
            id: call.external_id,
            call_url: call.call_url,
            start_time: call.start_time.iso8601,
            end_time: call.end_time.iso8601,
          }
        )
      end
    end

    context "purchase has a commission", :vcr do
      let(:commission) { create(:commission) }
      let(:commission_file) { fixture_file_upload("spec/support/fixtures/test.pdf") }
      let!(:purchase_custom_field_text) { create(:purchase_custom_field, purchase: commission.deposit_purchase, name: "What's your pet's name?", value: "Fido") }
      let!(:purchase_custom_field_file) { create(:purchase_custom_field, field_type: CustomField::TYPE_FILE, purchase: commission.deposit_purchase, name: CustomField::FILE_FIELD_NAME, value: nil) }

      before do
        commission.files.attach(commission_file)
        purchase_custom_field_file.files.attach(file_fixture("test.pdf"))
        purchase_custom_field_file.files.attach(file_fixture("smilie.png"))
      end

      it "includes the commission and custom fields" do
        file = commission.files.first
        props = described_class.new(purchase: commission.deposit_purchase).customer(pundit_user:)
        expect(props[:commission]).to eq(
          {
            id: commission.external_id,
            files: [
              {
                id: file.signed_id,
                name: "test",
                size: 8278,
                extension: "PDF",
                key: file.key
              }
            ],
            status: "in_progress",
          }
        )
        expect(props[:custom_fields]).to eq(
          [
            {
              type: "text",
              attribute: "What's your pet's name?",
              value: "Fido"
            },
            {
              attribute: "File upload",
              type: "file",
              files: [
                {
                  id: purchase_custom_field_file.files.first.signed_id,
                  name: "test",
                  size: 8278,
                  extension: "PDF",
                  key: purchase_custom_field_file.files.first.key
                },
                {
                  id: purchase_custom_field_file.files.second.signed_id,
                  name: "smilie",
                  size: 100406,
                  extension: "PNG",
                  key: purchase_custom_field_file.files.second.key
                }
              ]
            },
          ]
        )
      end
    end

    context "purchase has an installment plan" do
      let(:installment_plan) { create(:product_installment_plan, number_of_installments: 3, recurrence: "monthly") }
      let(:purchase) { create(:installment_plan_purchase, link: installment_plan.link) }

      it "includes the installment plan" do
        props = described_class.new(purchase:).customer(pundit_user:)

        expect(props[:subscription]).to eq(
          {
            id: purchase.subscription.external_id,
            status: "alive",
            remaining_charges: 2,
            is_installment_plan: true,
          }
        )
        expect(props[:price]).to include(
          recurrence: "monthly",
        )
      end
    end

    context "purchase has a utm link" do
      let(:utm_link) { create(:utm_link) }
      let(:purchase) { create(:purchase, utm_link:) }
      let!(:utm_link_driven_sale) { create(:utm_link_driven_sale, purchase:, utm_link:) }

      it "includes the utm_link" do
        expect(described_class.new(purchase:).customer(pundit_user:)[:utm_link]).to eq(
          {
            title: utm_link.title,
            utm_url: utm_link.utm_url,
            source: utm_link.utm_source,
            medium: utm_link.utm_medium,
            campaign: utm_link.utm_campaign,
            term: utm_link.utm_term,
            content: utm_link.utm_content,
          }
        )
      end
    end

    context "purchase has review videos" do
      let(:purchase) { create(:purchase) }
      let(:product_review) { create(:product_review, purchase:) }

      let!(:alive_approved_video) { create(:product_review_video, :approved, product_review:) }
      let!(:alive_pending_video) { create(:product_review_video, :pending_review, product_review:) }
      let!(:soft_deleted_video) { create(:product_review_video, :approved, product_review:, deleted_at: Time.current) }

      it "includes the review videos" do
        props = described_class.new(purchase: purchase.reload).customer(pundit_user:)
        expect(props[:review][:videos]).to contain_exactly(
          ProductReviewVideoPresenter.new(alive_approved_video).props(pundit_user:),
          ProductReviewVideoPresenter.new(alive_pending_video).props(pundit_user:),
        )
      end
    end

    context "purchase has downloads" do
      let(:purchase) { create(:purchase) }

      before do
        create(:url_redirect, purchase:, uses: 5)
      end

      it "returns the download count" do
        presenter = described_class.new(purchase: purchase.reload)
        expect(presenter.download_count).to eq(5)
      end
    end

    context "purchase without url_redirect" do
      let(:purchase) { create(:purchase) }

      it "returns 0 for download count" do
        presenter = described_class.new(purchase:)
        expect(presenter.download_count).to eq(0)
      end
    end

    context "purchase for coffee product" do
      let(:coffee_user) { create(:user, :eligible_for_service_products) }
      let(:coffee_product) { create(:product, user: coffee_user, native_type: Link::NATIVE_TYPE_COFFEE) }
      let(:purchase) { create(:purchase, link: coffee_product, seller: coffee_user) }

      before do
        create(:url_redirect, purchase:, uses: 10)
      end

      it "returns nil for download count" do
        presenter = described_class.new(purchase: purchase.reload)
        expect(presenter.download_count).to be_nil
      end
    end

    context "purchase for bundle" do
      let(:purchase) { create(:purchase, is_bundle_purchase: true) }

      before do
        create(:url_redirect, purchase:, uses: 10)
      end

      it "returns nil for download count" do
        presenter = described_class.new(purchase: purchase.reload)
        expect(presenter.download_count).to be_nil
      end
    end
  end

  describe "#customer_emails" do
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product) }

    context "with classic product" do
      it "returns success true with only receipt default values" do
        result = described_class.new(purchase:).customer_emails

        expect(result.count).to eq 1
        expect(result[0][:type]).to eq("receipt")
        expect(result[0][:id]).to be_present
        expect(result[0][:name]).to eq "Receipt"
        expect(result[0][:state]).to eq "Delivered"
        expect(result[0][:state_at]).to be_present
        expect(result[0][:url]).to eq purchase.receipt_url
      end

      it "returns success true with only receipt" do
        create(:customer_email_info_opened, purchase: purchase)
        result = described_class.new(purchase:).customer_emails

        expect(result.count).to eq 1
        expect(result[0][:type]).to eq("receipt")
        expect(result[0][:id]).to eq purchase.external_id
        expect(result[0][:name]).to eq "Receipt"
        expect(result[0][:state]).to eq "Opened"
        expect(result[0][:state_at]).to be_present
        expect(result[0][:url]).to eq purchase.receipt_url
      end

      it "returns success true with receipt and posts" do
        now = Time.current
        post1 = create(:installment, link: product, published_at: now - 10.seconds)
        post2 = create(:installment, link: product, published_at: now - 5.seconds)
        post3 = create(:installment, link: product, published_at: nil)

        create(:customer_email_info_opened, purchase: purchase)
        create(:creator_contacting_customers_email_info_delivered, installment: post1, purchase: purchase)
        create(:creator_contacting_customers_email_info_opened, installment: post2, purchase: purchase)
        create(:creator_contacting_customers_email_info_delivered, installment: post3, purchase: purchase)
        post_from_diff_user = create(:installment, link: product, seller: create(:user), published_at: Time.current)
        create(:creator_contacting_customers_email_info_delivered, installment: post_from_diff_user, purchase: purchase)

        result = described_class.new(purchase:).customer_emails

        expect(result.count).to eq 4

        expect(result[0][:type]).to eq("receipt")
        expect(result[0][:id]).to eq purchase.external_id
        expect(result[0][:state]).to eq "Opened"
        expect(result[0][:url]).to eq purchase.receipt_url

        expect(result[1][:type]).to eq("post")
        expect(result[1][:id]).to eq post2.external_id
        expect(result[1][:state]).to eq "Opened"

        expect(result[2][:type]).to eq("post")
        expect(result[2][:id]).to eq post1.external_id
        expect(result[2][:state]).to eq "Delivered"

        expect(result[3][:type]).to eq("post")
        expect(result[3][:id]).to eq post3.external_id
        expect(result[3][:state]).to eq "Delivered"
      end
    end

    context "with subscription product" do
      it "returns all receipts and posts ordered by date", :vcr do
        product = create(:membership_product, subscription_duration: "monthly", user: seller)
        buyer = create(:user, credit_card: create(:credit_card))
        subscription = create(:subscription, link: product, user: buyer)

        travel_to 1.month.ago

        original_purchase = create(:purchase_with_balance,
                                   link: product,
                                   seller: product.user,
                                   subscription:,
                                   purchaser: buyer,
                                   is_original_subscription_purchase: true)
        create(:customer_email_info_opened, purchase: original_purchase)

        travel_back

        first_post = create(:published_installment, link: product, name: "Thanks for buying!")

        travel 1

        recurring_purchase = create(:purchase_with_balance,
                                    link: product,
                                    seller: product.user,
                                    subscription:,
                                    purchaser: buyer)

        travel 1

        second_post = create(:published_installment, link: product, name: "Will you review my course?")
        create(:creator_contacting_customers_email_info_opened, installment: second_post, purchase: original_purchase)

        travel 1

        create(:customer_email_info_opened, purchase: recurring_purchase)
        create(:creator_contacting_customers_email_info_delivered, installment: first_post, purchase: original_purchase)

        unrelated_post = create(:published_installment, link: product, name: "Message to other folks!")
        create(:creator_contacting_customers_email_info_delivered, installment: unrelated_post)

        result = described_class.new(purchase: original_purchase).customer_emails

        expect(result.count).to eq 4

        expect(result[0][:type]).to eq("receipt")
        expect(result[0][:id]).to eq original_purchase.external_id
        expect(result[0][:name]).to eq "Receipt"
        expect(result[0][:state]).to eq "Opened"
        expect(result[0][:url]).to eq original_purchase.receipt_url

        expect(result[1][:type]).to eq("receipt")
        expect(result[1][:id]).to eq recurring_purchase.external_id
        expect(result[1][:name]).to eq "Receipt"
        expect(result[1][:state]).to eq "Opened"
        expect(result[1][:url]).to eq recurring_purchase.receipt_url

        expect(result[2][:type]).to eq("post")
        expect(result[2][:id]).to eq second_post.external_id
        expect(result[2][:state]).to eq "Opened"

        expect(result[3][:type]).to eq("post")
        expect(result[3][:id]).to eq first_post.external_id
        expect(result[3][:state]).to eq "Delivered"
      end

      it "includes receipts for free trial original purchases" do
        product = create(:membership_product, :with_free_trial_enabled, user: seller)
        original_purchase = create(:membership_purchase, link: product, seller:, is_free_trial_purchase: true, purchase_state: "not_charged")
        create(:customer_email_info_opened, purchase: original_purchase)

        result = described_class.new(purchase: original_purchase).customer_emails

        expect(result.count).to eq 1

        email_info = result[0]
        expect(email_info[:type]).to eq("receipt")
        expect(email_info[:id]).to eq original_purchase.external_id
        expect(email_info[:name]).to eq "Receipt"
        expect(email_info[:state]).to eq "Opened"
        expect(email_info[:url]).to eq original_purchase.receipt_url
      end
    end

    context "when purchase uses a charge receipt" do
      let(:product) { create(:product, user: seller) }
      let(:purchase) { create(:purchase, link: product) }
      let(:charge) { create(:charge, purchases: [purchase], seller:) }
      let(:order) { charge.order }
      let!(:email_info) do
        create(
          :customer_email_info,
          purchase_id: nil,
          state: :opened,
          opened_at: Time.current,
          email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
          email_info_charge_attributes: { charge_id: charge.id }
        )
      end

      before do
        order.purchases << purchase
      end

      it "returns EmailInfo from charge" do
        result = described_class.new(purchase:).customer_emails

        expect(result.count).to eq 1

        email_info = result[0]
        expect(email_info[:type]).to eq("receipt")
        expect(email_info[:id]).to eq purchase.external_id
        expect(email_info[:name]).to eq "Receipt"
        expect(email_info[:state]).to eq "Opened"
        expect(email_info[:url]).to eq purchase.receipt_url
      end
    end

    context "for bundle purchase" do
      include_context "customer drawer missed posts setup"
      include_context "with bundle purchase setup"

      it "returns receipt only for bundle purchase" do
        expect(CustomersService).to receive(:find_sent_posts_for).with(bundle_purchase).and_call_original
        emails_for_bundle_purchase = described_class.new(purchase: bundle_purchase).customer_emails

        expect(emails_for_bundle_purchase.count).to eq 1

        expect(emails_for_bundle_purchase[0][:type]).to eq("receipt")
        expect(emails_for_bundle_purchase[0][:id]).to eq bundle_purchase.external_id
      end

      it "doesn't return receipt for bundle product purchase" do
        product_a_purchase = bundle_purchase.product_purchases.find_by(link: product_a)
        product_b_purchase = bundle_purchase.product_purchases.find_by(link: product_b)

        expect(CustomersService).to receive(:find_sent_posts_for).with(product_a_purchase).and_call_original
        emails_for_product_a_purchase = described_class.new(purchase: product_a_purchase).customer_emails

        expect(emails_for_product_a_purchase.count).to eq 0

        expect(CustomersService).to receive(:find_sent_posts_for).with(product_b_purchase).and_call_original
        emails_for_product_b_purchase = described_class.new(purchase: product_b_purchase).customer_emails

        expect(emails_for_product_b_purchase.count).to eq 0
      end
    end
  end

  describe "#charge" do
    let(:purchase) { create(:physical_purchase, stripe_partially_refunded: true, chargeback_date: Time.current, created_at: 7.months.ago, card_type: CardType::PAYPAL) }

    before do
      purchase.link.update!(price_currency_type: Currency::EUR, price_cents: 100)
      allow_any_instance_of(Purchase).to receive(:get_rate).with(Currency::EUR).and_return(0.8)
    end

    it "returns the correct props" do
      expect(described_class.new(purchase:).charge).to eq(
        {
          id: purchase.external_id,
          chargedback: true,
          created_at: purchase.created_at.iso8601,
          amount_refundable: 80,
          currency_type: "eur",
          is_upgrade_purchase: false,
          partially_refunded: true,
          refunded: false,
          transaction_url_for_seller: nil,
          paypal_refund_expired: true,
        }
      )
    end
  end
end
