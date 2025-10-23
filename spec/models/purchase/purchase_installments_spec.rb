# frozen_string_literal: true

require "spec_helper"

describe "PurchaseInstallments", :vcr do
  include CurrencyHelper
  include ProductsHelper

  describe ".product_installments" do
    it "can return installments for several purchases" do
      product = create(:product)
      variant = create(:variant, variant_category: create(:variant_category, link: product))
      purchase_1 = create(:purchase, link: product, variant_attributes: [variant], price_cents: 100)
      installment_1 = create(:installment, link: product, published_at: 30.minutes.ago)
      create(:creator_contacting_customers_email_info_sent, purchase: purchase_1, installment: installment_1)

      seller_post = create(:seller_installment, seller: product.user, published_at: 15.minutes.ago, json_data: { bought_products: [product.unique_permalink, create(:product).unique_permalink] })
      create(:creator_contacting_customers_email_info_sent, purchase: purchase_1, installment: seller_post)

      seller_post_2 = create(:seller_installment, seller: product.user, published_at: 20.minutes.ago,
                                                  json_data: { bought_products: [product.unique_permalink, create(:product).unique_permalink] })
      create(:creator_contacting_customers_email_info_sent,
             purchase: create(:purchase, link: create(:product, user: product.user), email: purchase_1.email),
             installment: seller_post_2)

      seller_post_for_variant = create(:seller_installment, seller: product.user, published_at: 25.minutes.ago, json_data: { bought_products: [create(:product).unique_permalink], bought_variants: [variant.external_id] })
      create(:creator_contacting_customers_email_info_sent, purchase: purchase_1, installment: seller_post_for_variant)

      create(:seller_installment, seller: product.user, published_at: Time.current, json_data: { bought_products: [create(:product).unique_permalink, create(:product).unique_permalink] })

      profile_only_post = create(:installment, link: product, shown_on_profile: true, send_emails: false, published_at: 5.minutes.ago, paid_more_than_cents: 100)
      profile_only_post_2 = create(:installment, link: product, shown_on_profile: true, send_emails: false, published_at: 35.minutes.ago) # Published before purchase
      purchase_2 = create(:purchase)
      installment_2 = create(:installment, link: purchase_2.link, published_at: Time.current)
      create(:creator_contacting_customers_email_info_sent, purchase: purchase_2, installment: installment_2)
      create(:purchase, link: product, email: purchase_2.email)
      purchase_3 = create(:purchase)
      installment_3 = create(:installment, link: purchase_3.link, published_at: Time.current)
      create(:creator_contacting_customers_email_info_sent, purchase: purchase_3, installment: installment_3, sent_at: 4.minutes.from_now)

      profile_only_seller_post = create(:seller_installment, send_emails: false, shown_on_profile: true, seller: purchase_3.link.user, published_at: 10.minutes.ago, json_data: { bought_products: [purchase_3.link.unique_permalink, create(:product).unique_permalink] })

      create(:seller_installment, send_emails: false, shown_on_profile: true, seller: create(:user), published_at: Time.current)

      expect(Purchase.product_installments(purchase_ids: [purchase_1.id, purchase_3.id])).to match_array([installment_3, profile_only_post, profile_only_seller_post, seller_post, seller_post_2, seller_post_for_variant, installment_1, profile_only_post_2])
      expect(Purchase.product_installments(purchase_ids: [purchase_2.id])).to eq([installment_2])
    end

    context "when purchased product(s) have should_show_all_posts enabled" do
      let(:enabled_product) { create(:product, should_show_all_posts: true) }
      let(:enabled_product_variant) { create(:variant, variant_category: create(:variant_category, link: enabled_product)) }
      let(:enabled_purchase) { create(:purchase, link: enabled_product, seller: enabled_product.user) }
      let(:enabled_purchase_with_variant) { create(:purchase, link: enabled_product, variant_attributes: [enabled_product_variant]) }

      it "returns all posts for purchases of products" do
        enabled_product_post = create(:installment, link: enabled_product, published_at: 1.day.ago)
        create(:installment, link: enabled_product, published_at: 1.day.ago, created_before: enabled_purchase.created_at - 1.hour)
        enabled_product_variant_post = create(:variant_installment, link: enabled_product, published_at: 1.day.ago, base_variant: enabled_product_variant)
        multi_product_post = create(:seller_installment, seller: enabled_product.user, published_at: 1.day.ago, bought_products: [enabled_product.unique_permalink])
        multi_product_variant_post = create(:seller_installment, seller: enabled_product.user, published_at: 1.day.ago, bought_products: [create(:product, user: enabled_product.user).unique_permalink], bought_variants: [enabled_product_variant.external_id])
        create(:creator_contacting_customers_email_info_sent, purchase: enabled_purchase, installment: enabled_product_post)

        disabled_product = create(:product, should_show_all_posts: false)
        disabled_product_variant = create(:variant, variant_category: create(:variant_category, link: enabled_product))
        disabled_purchase = create(:purchase, link: disabled_product, seller: disabled_product.user)
        disabled_purchase_with_variant = create(:purchase, link: disabled_product, variant_attributes: [disabled_product_variant])
        create(:installment, link: disabled_product, published_at: 1.day.ago)
        create(:variant_installment, link: disabled_product, published_at: 1.day.ago, base_variant: disabled_product_variant)
        create(:seller_installment, seller: disabled_product.user, published_at: 1.day.ago, bought_products: [disabled_product.unique_permalink])
        create(:seller_installment, seller: disabled_product.user, published_at: 1.day.ago, bought_products: [disabled_product.unique_permalink], bought_variants: [disabled_product_variant.external_id])

        expect(Purchase.product_installments(purchase_ids: [disabled_purchase.id, disabled_purchase_with_variant.id])).to be_empty
        expect(Purchase.product_installments(purchase_ids: [enabled_purchase.id]).map(&:id)).to match_array [enabled_product_post, multi_product_post].map(&:id)
        expect(Purchase.product_installments(purchase_ids: [enabled_purchase_with_variant.id]).map(&:id)).to match_array [enabled_product_post, enabled_product_variant_post, multi_product_post, multi_product_variant_post].map(&:id)
        expect(Purchase.product_installments(purchase_ids: [enabled_purchase.id, enabled_purchase_with_variant.id, disabled_purchase.id, disabled_purchase_with_variant.id]).map(&:id)).to match_array [enabled_product_post, enabled_product_variant_post, multi_product_post, multi_product_variant_post].map(&:id)
      end

      it "excludes past posts that are not directly targeted at the purchased product or variant" do
        create(:seller_installment, seller: enabled_product.user, published_at: 1.day.ago)
        create(:seller_installment, seller: enabled_product.user, published_at: 1.day.ago, bought_products: [create(:product).unique_permalink])
        create(:seller_installment, seller: enabled_product.user, published_at: 1.day.ago, bought_variants: [create(:variant).external_id])

        expect(Purchase.product_installments(purchase_ids: [enabled_purchase.id, enabled_purchase_with_variant.id])).to eq []
      end
    end
  end

  describe "#product_installments" do
    before do
      @seller = create(:user)
      @product = create(:product, user: @seller)
    end

    describe "link installments" do
      before do
        @post1 = create(:installment, link: @product, published_at: 1.week.ago)
        @post2 = create(:installment, link: @product, published_at: 1.hour.ago)
        @post3 = create(:installment, link: @product)
        @post4 = create(:installment, link: @product, published_at: 1.week.ago, deleted_at: Time.current)
        @profile_only_post = create(:installment, link: @product, shown_on_profile: true, send_emails: false, published_at: 1.hour.ago)
      end

      it "only includes published installments" do
        purchase = create(:purchase, link: @product, created_at: Time.current, price_cents: 100)
        create(:creator_contacting_customers_email_info_sent, purchase:, installment: @post2)
        installments = purchase.product_installments
        expect(installments.count).to eq(2)
        expect(installments.include?(@post1)).to be(false)
        expect(installments.include?(@post2)).to be(true)
        expect(installments.include?(@post3)).to be(false)
        expect(installments.include?(@post4)).to be(false)
        expect(installments.include?(@profile_only_post)).to be(true)
      end

      describe "variant installments" do
        it "only includes installments from the purchased variant" do
          category = create(:variant_category, title: "title", link: @product)
          variant1 = create(:variant, variant_category: category, name: "V1")
          variant2 = create(:variant, variant_category: category, name: "V1")
          variant_installment1 = create(:installment, link: @product, base_variant: variant1, installment_type: "variant", published_at: Time.current)
          create(:installment, link: @product, base_variant: variant2, installment_type: "variant", published_at: 5.minutes.ago)
          variant1_profile_only_post = create(:installment, link: @product, shown_on_profile: true, send_emails: false, base_variant: variant1, installment_type: "variant", published_at: 10.minutes.ago)

          purchase = create(:purchase, link: @product, created_at: Time.current, price_cents: 100)
          purchase.variant_attributes << variant1
          create(:creator_contacting_customers_email_info_sent, purchase:, installment: @post2, sent_at: 3.hours.from_now)
          create(:creator_contacting_customers_email_info_sent, purchase:, installment: variant_installment1, sent_at: 4.hours.from_now)
          installments = purchase.product_installments
          expect(installments).to eq([variant_installment1, @post2, variant1_profile_only_post, @profile_only_post])

          variant_purchase = create(:purchase, link: @product)
          variant_purchase.variant_attributes << variant1

          variants_specific_seller_post = create(:seller_installment, seller: @product.user, published_at: 5.hours.ago)
          variants_specific_seller_post.bought_variants = [variant1.external_id, create(:variant, variant_category: category).external_id]
          variants_specific_seller_post.save!
          create(:creator_contacting_customers_email_info_sent, purchase: variant_purchase, installment: variants_specific_seller_post, sent_at: 1.week.ago)

          profile_only_seller_post = create(:seller_installment, send_emails: false, shown_on_profile: true, seller: @product.user, published_at: 6.hours.ago)
          profile_only_seller_post.bought_variants = [variant1.external_id, create(:variant, variant_category: category).external_id]
          profile_only_seller_post.save!

          seller_post_other_variants = create(:seller_installment, send_emails: false, shown_on_profile: true, seller: @product.user, published_at: Time.current)
          seller_post_other_variants.bought_variants = [variant2. external_id, create(:variant, variant_category: category).external_id]
          seller_post_other_variants.save!

          installments = variant_purchase.product_installments
          expect(installments).to eq([variant1_profile_only_post, @profile_only_post, profile_only_seller_post, variants_specific_seller_post])
        end
      end
    end

    describe "workflow installments" do
      it "gets installments only from product workflow" do
        @product.update!(should_show_all_posts: true)

        product_workflow = create(:workflow, seller: @seller, link: @product, created_at: 1.week.ago)
        seller_workflow = create(:workflow, seller: @seller, link: nil, created_at: 1.week.ago)
        installment1 = create(:installment, workflow: seller_workflow, published_at: Time.current)
        create(:installment_rule, installment: installment1, delayed_delivery_time: 3.days)
        installment2 = create(:installment, link: @product, workflow: product_workflow, published_at: Time.current)
        create(:installment_rule, installment: installment2, delayed_delivery_time: 3.days)
        installment3 = create(:installment, link: @product, workflow: product_workflow, published_at: Time.current)
        create(:installment_rule, installment: installment3, delayed_delivery_time: 1.day)
        installment4 = create(:installment, link: @product, workflow: product_workflow, published_at: Time.current)
        create(:installment_rule, installment: installment4, delayed_delivery_time: 3.days)

        purchase = create(:purchase, link: @product, created_at: 5.days.ago, price_cents: 100)
        create(:creator_contacting_customers_email_info_sent, purchase:, installment: installment2)
        create(:creator_contacting_customers_email_info_sent, purchase:, installment: installment3)
        installments = purchase.product_installments
        expect(installments.count).to eq(2)
        expect(installments.include?(installment1)).to be(false)
        expect(installments.include?(installment2)).to be(true)
        expect(installments.include?(installment3)).to be(true)
        expect(installments.include?(installment4)).to be(false)
      end
    end

    describe "link and workflow" do
      it "includes installments in the correct order" do
        @product.update!(should_show_all_posts: true)

        installment1 = create(:installment, link: @product, published_at: 2.days.ago)
        past_installment = create(:installment, link: @product, published_at: 1.week.ago)
        workflow = create(:workflow, seller: @seller, link: @product, created_at: 1.week.ago)
        workflow_installment = create(:installment, workflow:, published_at: 1.day.ago)
        create(:installment_rule, installment: workflow_installment, delayed_delivery_time: 1.day)
        create(:installment, workflow:, link: @product, published_at: 1.day.ago)
        profile_only_installment = create(:installment, link: @product, shown_on_profile: true, send_emails: false, published_at: 1.minutes.ago)

        purchase = create(:purchase, link: @product, created_at: 2.days.ago, price_cents: 100)
        create(:creator_contacting_customers_email_info_sent, purchase:, installment: installment1, sent_at: 2.minute.ago)
        create(:creator_contacting_customers_email_info_opened, purchase:, installment: workflow_installment, sent_at: 1.hour.ago, opened_at: 5.minutes.ago)
        installments = purchase.product_installments
        expect(installments).to eq([profile_only_installment, installment1, workflow_installment, past_installment])
      end
    end

    describe "mobile api" do
      before do
        @product = create(:product)
        @product.product_files << create(
          :product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter1.mp4"
        )
        @purchase = create(:purchase_with_balance, link: @product)
      end

      it "does not throw an exception when a url redirect for a purchase is nil" do
        @purchase.url_redirect = nil
        @purchase.save!
        expect { @purchase.json_data_for_mobile }.not_to raise_error
      end

      it "returns update information if available" do
        good_installment = create(:installment, link: @product, published_at: Time.current, name: "Good installment")
        create(:installment, link: @product, published_at: 10.hours.ago, name: "old published installment")
        create(:installment, link: @product, published_at: Time.current, deleted_at: Time.current, name: "deleted installment")
        create(:installment, link: @product, name: "should not appear")
        create(:creator_contacting_customers_email_info_sent, purchase: @purchase, installment: good_installment)
        json_data = @purchase.json_data_for_mobile
        expect(json_data[:updates_data]).to eq nil
        expect(json_data[:product_updates_data].as_json).to eq [good_installment.installment_mobile_json_data(purchase: @purchase)].as_json
      end

      it "returns subscription expiration information for a subscription purchase" do
        purchase = create(:membership_purchase)
        ended_at = 1.day.ago
        subscription = purchase.subscription
        subscription.update!(deactivated_at: ended_at, failed_at: ended_at)

        json_data = purchase.json_data_for_mobile

        expect(json_data[:subscription_data]).to be_present
        expect(json_data[:subscription_data][:subscribed_at]).to eq subscription.created_at.as_json
        expect(json_data[:subscription_data][:id]).to eq subscription.external_id

        expect(json_data[:subscription_data][:ended_at]).to eq ended_at.as_json
        expect(json_data[:subscription_data][:ended_reason]).to eq "failed_payment"
      end
    end

    describe "creator api" do
      before do
        @free_purchase = create(:purchase, link: create(:product, price_range: "0+"), price_cents: 0, stripe_transaction_id: nil, stripe_fingerprint: nil)
        @paid_purchase = create(:purchase)
      end

      it "returns the correct json format for free purchase" do
        json_response = @free_purchase.as_json(creator_app_api: true)
        expect(json_response[:email]).to eq @free_purchase.email
        expect(json_response[:timestamp]).to eq "less than a minute ago"
        expect(json_response[:created_at]).to eq @free_purchase.created_at
        expect(json_response[:price]).to eq "$0"
        expect(json_response[:link_name]).to eq @free_purchase.link.name
        expect(json_response[:alert]).to eq "New download of #{@free_purchase.link.name}"
      end

      it "returns the correct json format for nonfree purchase" do
        @paid_purchase = create(:purchase)
        json_response = @paid_purchase.as_json(creator_app_api: true)
        expect(json_response[:email]).to eq @paid_purchase.email
        expect(json_response[:timestamp]).to eq "less than a minute ago"
        expect(json_response[:created_at]).to eq @paid_purchase.created_at
        expect(json_response[:price]).to eq "$1"
        expect(json_response[:link_name]).to eq @paid_purchase.link.name
        expect(json_response[:alert]).to eq "New sale of #{@paid_purchase.link.name} for #{@paid_purchase.formatted_total_price}"
      end
    end

    it "calls class method .product_installments for current purchase" do
      purchase = create(:purchase)
      installments_double = double
      expect(Purchase).to receive(:product_installments).with(purchase_ids: [purchase.id]).and_return(installments_double)
      expect(purchase.product_installments).to eq(installments_double)
    end
  end

  describe "#update_json_data_for_mobile" do
    let(:user) { create(:user, credit_card: create(:credit_card)) }

    context "for subscriptions" do
      let(:product) { create(:subscription_product) }
      let(:subscription) { create(:subscription, user:, link: product) }
      let(:purchase_1) do create(:purchase, link: product, email: user.email,
                                            is_original_subscription_purchase: true,
                                            subscription:, created_at: 2.days.ago) end
      let(:post_1) { create(:installment, link: purchase_1.link, published_at: 1.day.ago) }
      let(:subject) { purchase_1.update_json_data_for_mobile }
      before do
        create(:creator_contacting_customers_email_info_sent, purchase: purchase_1, installment: post_1, sent_at: 1.hour.ago)
      end

      it "returns posts for all purchases of the product" do
        subscription_2 = create(:subscription, user: subscription.user, link: product)
        purchase_2 = create(:purchase, link: product, email: subscription_2.user.email,
                                       is_original_subscription_purchase: true,
                                       subscription: subscription_2, created_at: 1.day.ago)
        post_2 = create(:installment, link: purchase_2.link, published_at: 1.hour.ago)
        create(:creator_contacting_customers_email_info_sent, purchase: purchase_2, installment: post_2, sent_at: 2.hours.ago)

        purchase_3 = create(:purchase, link: product, email: subscription_2.user.email,
                                       is_original_subscription_purchase: false,
                                       subscription: subscription_2, created_at: 1.hour.ago)
        post_3 = create(:installment, link: purchase_3.link, published_at: Time.current)
        create(:creator_contacting_customers_email_info_sent, purchase: purchase_3, installment: post_3, sent_at: 1.hour.from_now)

        all_posts = [post_3.external_id, post_1.external_id, post_2.external_id]
        expect(purchase_1.update_json_data_for_mobile.size).to eq(3)
        expect(purchase_1.update_json_data_for_mobile.map { |post| post[:external_id] }).to eq(all_posts)
        expect(purchase_2.update_json_data_for_mobile.size).to eq(3)
        expect(purchase_2.update_json_data_for_mobile.map { |post| post[:external_id] }).to eq(all_posts)
        expect(purchase_3.update_json_data_for_mobile.size).to eq(3)
        expect(purchase_3.update_json_data_for_mobile.map { |post| post[:external_id] }).to eq(all_posts)
      end

      context "when it is deactivated" do
        let(:subscription) { create(:subscription, user:, link: product, deactivated_at: Time.current) }

        context "and access is blocked on cancellation" do
          let(:product) { create(:subscription_product, block_access_after_membership_cancellation: true) }

          it "does not return posts" do
            expect(subject).to be_empty
          end
        end

        context "when access not blocked on cancellation" do
          let(:product) { create(:subscription_product, block_access_after_membership_cancellation: false) }

          it "does return posts" do
            expect(subject).to match_array(a_hash_including(external_id: post_1.external_id))
          end
        end
      end
    end

    context "for products" do
      let(:product) { create(:product, is_licensed: true) }
      let(:purchase) { create(:purchase, purchaser: user, email: user.email, link: product, price_cents: 100, license: create(:license)) }
      let(:installment) { create(:installment, link: purchase.link, published_at: Time.current) }
      let(:subject) { purchase.update_json_data_for_mobile }

      before do
        create(:creator_contacting_customers_email_info, purchase:, installment:)
      end

      shared_examples "not returns post" do
        it "does not return posts" do
          expect(subject).to be_empty
        end
      end

      shared_examples "returns post" do
        it "does return posts" do
          expect(subject).to match_array(a_hash_including(external_id: installment.external_id))
        end
      end

      context "with a failed purchase" do
        let(:purchase) { create(:failed_purchase, purchaser: user, email: user.email, link: product) }

        include_examples "not returns post"
      end

      context "with fully refunded purchase" do
        let(:purchase) { create(:refunded_purchase, purchaser: user, email: user.email, link: product, price_cents: 100, license: create(:license)) }

        include_examples "not returns post"
      end

      context "with chargedback purchase" do
        let(:purchase) { create(:purchase, purchaser: user, email: user.email, link: product, price_cents: 100, license: create(:license), chargeback_date: Time.current) }

        include_examples "not returns post"
      end

      context "with chargedback purchase" do
        let(:purchase) { create(:purchase, purchaser: user, email: user.email, link: product, price_cents: 100, license: create(:license), chargeback_date: Time.current) }

        include_examples "not returns post"
      end

      context "with gift sent purchase" do
        let(:purchase) { create(:purchase, purchaser: user, email: user.email, link: product, is_gift_sender_purchase: true) }

        include_examples "not returns post"
      end

      context "with chargedback reversed purchase" do
        let(:purchase) { create(:purchase, purchaser: user, email: user.email, link: product, price_cents: 100, license: create(:license), chargeback_date: Time.current, chargeback_reversed: true) }

        include_examples "returns post"
      end

      context "with partially refunded purchases" do
        let(:purchase) { create(:purchase, purchaser: user, email: user.email, link: product, stripe_partially_refunded: true) }

        include_examples "returns post"
      end

      context "with test purchases" do
        let(:purchase) { create(:test_purchase, purchaser: user, email: user.email, link: product) }

        include_examples "returns post"
      end

      context "with gift received purchase" do
        let(:purchase) { create(:purchase, purchaser: user, email: user.email, link: product, is_gift_receiver_purchase: true) }

        include_examples "returns post"
      end
    end

    context "lapsed subscriptions" do
      before do
        @purchase = create(:membership_purchase)
        @purchase.subscription.update!(cancelled_at: 1.day.ago)
        @product = @purchase.link
        post = create(:seller_installment, seller: @product.user,
                                           bought_products: [@product.unique_permalink],
                                           published_at: 1.day.ago)
        create(:creator_contacting_customers_email_info, installment: post, purchase: @purchase)
      end

      it "returns an empty array when user should lose access after cancellation" do
        @product.update!(block_access_after_membership_cancellation: true)
        expect(@purchase.update_json_data_for_mobile).to eq []
      end

      it "returns content when user should not lose access after cancellation" do
        expect(@purchase.update_json_data_for_mobile).not_to be_empty
      end
    end

    context "updated subscriptions" do
      it "returns posts associated with all purchases, including the updated original purchase" do
        product = create(:membership_product)
        subscription = create(:subscription, link: product)
        email = generate(:email)
        old_purchase = create(:membership_purchase, link: product, subscription:, email:, is_archived_original_subscription_purchase: true)
        new_purchase = create(:membership_purchase, link: product, subscription:, email:, purchase_state: "not_charged")
        subscription.reload

        post_1 = create(:installment, link: product, published_at: 1.day.ago)
        create(:creator_contacting_customers_email_info_sent, purchase: new_purchase, installment: post_1, sent_at: 1.hour.ago)
        post_2 = create(:installment, link: product, published_at: 1.day.ago)
        create(:creator_contacting_customers_email_info_sent, purchase: old_purchase, installment: post_2, sent_at: 1.hour.ago)

        expect(old_purchase.update_json_data_for_mobile.map { |post| post[:external_id] }).to match_array [post_1.external_id, post_2.external_id]
        expect(new_purchase.update_json_data_for_mobile.map { |post| post[:external_id] }).to match_array [post_1.external_id, post_2.external_id]
      end
    end
  end

  describe "#schedule_workflows" do
    before do
      @product = create(:product)
      @workflow = create(:workflow, seller: @product.user, link: @product, created_at: Time.current)
      @installment = create(:installment, link: @product, workflow: @workflow, published_at: Time.current)
      create(:installment_rule, installment: @installment, delayed_delivery_time: 1.day)
      @purchase = create(:purchase, link: @product)
    end

    it "enqueues SendWorkflowInstallmentWorker for the workflow installments" do
      @purchase.schedule_workflows([@workflow])
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@installment.id, 1, @purchase.id, nil, nil)
    end

    it "schedules matching non-abandoned cart workflow installments" do
      abandoned_cart_workflow = create(:abandoned_cart_workflow, published_at: 1.day.ago, seller_id: @purchase.seller_id, bought_products: [@product.unique_permalink])
      abandoned_cart_workflow_installment = abandoned_cart_workflow.installments.sole
      abandoned_cart_workflow_installment_rule = create(:installment_rule, installment: abandoned_cart_workflow_installment, time_period: "hour", delayed_delivery_time: 24.hours)

      @purchase.schedule_workflows(Workflow.all)

      expect(SendWorkflowInstallmentWorker.jobs.size).to eq(1)
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@installment.id, @installment.installment_rule.version, @purchase.id, nil, nil)
      expect(SendWorkflowInstallmentWorker).to_not have_enqueued_sidekiq_job(abandoned_cart_workflow_installment.id, abandoned_cart_workflow_installment_rule.version, @purchase.id, nil, nil)
    end
  end

  describe "#schedule_workflows_for_variants" do
    before do
      @product = create(:product)
      vc = create(:variant_category, link: @product)
      @variant1 = create(:variant, variant_category: vc)
      @variant2 = create(:variant, variant_category: vc)

      # product workflow
      @product_workflow = create(:workflow, seller: @product.user, link: @product, created_at: Time.current)
      @product_installment = create(:installment, link: @product, workflow: @product_workflow, published_at: Time.current)
      create(:installment_rule, installment: @product_installment, delayed_delivery_time: 1.day)

      # variant 1 workflow
      @variant1_workflow = create(:variant_workflow, seller: @product.user, link: @product, base_variant: @variant1)
      @variant1_installment = create(:installment, link: @product, workflow: @variant1_workflow, published_at: Time.current)
      create(:installment_rule, installment: @variant1_installment, delayed_delivery_time: 1.day)

      # variant 2 workflow
      @variant2_workflow = create(:variant_workflow, seller: @product.user, link: @product, base_variant: @variant2)
      @variant2_installment = create(:installment, link: @product, workflow: @variant2_workflow, published_at: Time.current)
      create(:installment_rule, installment: @variant2_installment, delayed_delivery_time: 1.day)

      # seller workflow targeting variant 1
      @seller_workflow_variant_1 = create(:seller_workflow, seller: @product.user, bought_variants: [@variant1.external_id])
      @seller_variant_1_installment = create(:installment, link: @product, workflow: @seller_workflow_variant_1, published_at: Time.current)
      create(:installment_rule, installment: @seller_variant_1_installment, delayed_delivery_time: 1.day)

      # seller workflow targeting variant 2
      @seller_workflow_variant_2 = create(:seller_workflow, seller: @product.user, bought_variants: [@variant2.external_id])
      @seller_variant_2_installment = create(:installment, link: @product, workflow: @seller_workflow_variant_2, published_at: Time.current)
      create(:installment_rule, installment: @seller_variant_2_installment, delayed_delivery_time: 1.day)

      # seller workflow targeting both variants
      @seller_workflow_both_variants = create(:seller_workflow, seller: @product.user, bought_variants: [@variant1.external_id, @variant2.external_id])
      @seller_both_variants_installment = create(:installment, link: @product, workflow: @seller_workflow_both_variants, published_at: Time.current)
      create(:installment_rule, installment: @seller_both_variants_installment, delayed_delivery_time: 1.day)

      # seller workflow targeting neither variant
      @seller_workflow_neither_variant = create(:seller_workflow, seller: @product.user, bought_variants: [create(:variant).external_id])
      @seller_neither_variant_installment = create(:installment, link: @product, workflow: @seller_workflow_neither_variant, published_at: Time.current)
      create(:installment_rule, installment: @seller_neither_variant_installment, delayed_delivery_time: 1.day)

      # seller workflow targeting product
      @seller_workflow_product = create(:seller_workflow, seller: @product.user, bought_products: [@product.unique_permalink])
      @seller_product_installment = create(:installment, link: @product, workflow: @seller_workflow_product, published_at: Time.current)
      create(:installment_rule, installment: @seller_product_installment, delayed_delivery_time: 1.day)

      @purchase = create(:purchase, link: @product, variant_attributes: [@variant1])
    end

    it "enqueues SendWorkflowInstallmentWorker for the purchased variant's workflow installments" do
      @purchase.schedule_workflows_for_variants(excluded_variants: [@variant2])

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@variant1_installment.id, 1, @purchase.id, nil, nil)
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@seller_variant_1_installment.id, 1, @purchase.id, nil, nil)
    end

    it "enqueues SendWorkflowInstallmentWorker for seller workflows targeted at the purchased variant" do
      @purchase.schedule_workflows_for_variants(excluded_variants: [@variant2])

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@seller_variant_1_installment.id, 1, @purchase.id, nil, nil)
    end

    it "does not enqueue SendWorkflowInstallmentWorker for workflows that should already have been scheduled" do
      @purchase.schedule_workflows_for_variants(excluded_variants: [@variant2])

      expect(SendWorkflowInstallmentWorker).not_to have_enqueued_sidekiq_job(@product_installment.id, 1, @purchase.id, nil, nil)
      expect(SendWorkflowInstallmentWorker).not_to have_enqueued_sidekiq_job(@variant2_installment.id, 1, @purchase.id, nil, nil)
      expect(SendWorkflowInstallmentWorker).not_to have_enqueued_sidekiq_job(@seller_variant_2_installment.id, 1, @purchase.id, nil, nil)
      expect(SendWorkflowInstallmentWorker).not_to have_enqueued_sidekiq_job(@seller_both_variants_installment.id, 1, @purchase.id, nil, nil)
      expect(SendWorkflowInstallmentWorker).not_to have_enqueued_sidekiq_job(@seller_product_installment.id, 1, @purchase.id, nil, nil)
    end

    it "does not enqueue SendWorkflowInstallmentWorker for workflows that don't target the variant" do
      @purchase.schedule_workflows_for_variants(excluded_variants: [@variant2])

      expect(SendWorkflowInstallmentWorker).not_to have_enqueued_sidekiq_job(@seller_neither_variant_installment.id, 1, @purchase.id, nil, nil)
    end

    it "does not enqueue SendWorkflowInstallmentWorker if the workflow is deleted" do
      @variant1_workflow.update!(deleted_at: 1.day.ago)
      @purchase.schedule_workflows_for_variants(excluded_variants: [@variant2])

      expect(SendWorkflowInstallmentWorker).not_to have_enqueued_sidekiq_job(@variant1_installment.id, 1, @purchase.id, nil, nil)
    end

    it "does not enqueue SendWorkflowInstallmentWorker if old variants are the same as the existing ones" do
      @purchase.schedule_workflows_for_variants(excluded_variants: [@variant1])

      expect(SendWorkflowInstallmentWorker.jobs.size).to eq(0)
    end
  end

  describe "#schedule_all_workflows" do
    it "schedules all workflows that apply to the purchase" do
      user = create(:user)
      product = create(:product, user:)
      variant = create(:variant, variant_category: create(:variant_category, link: product))
      other_product = create(:product, user:)

      product_workflow = create(:workflow, seller: user, link: product)
      product_installment = create(:installment, workflow: product_workflow, published_at: Time.current)
      create(:installment_rule, installment: product_installment, delayed_delivery_time: 1.day)

      other_product_workflow = create(:workflow, seller: user, link: other_product)
      other_product_installment = create(:installment, workflow: other_product_workflow, published_at: Time.current)
      create(:installment_rule, installment: other_product_installment, delayed_delivery_time: 1.day)

      seller_product_workflow = create(:seller_workflow, seller: user, bought_products: [product.unique_permalink])
      seller_product_installment = create(:installment, workflow: seller_product_workflow, published_at: Time.current)
      create(:installment_rule, installment: seller_product_installment, delayed_delivery_time: 1.day)

      seller_variant_workflow = create(:seller_workflow, seller: user, bought_products: [product.unique_permalink])
      seller_variant_installment = create(:installment, workflow: seller_variant_workflow, published_at: Time.current)
      create(:installment_rule, installment: seller_variant_installment, delayed_delivery_time: 1.day)

      other_seller_workflow = create(:seller_workflow, seller: user, bought_products: [other_product.unique_permalink])
      other_seller_installment = create(:installment, workflow: other_seller_workflow, published_at: Time.current)
      create(:installment_rule, installment: other_seller_installment, delayed_delivery_time: 1.day)

      audience_workflow = create(:audience_workflow, seller: user)
      audience_installment = create(:installment, workflow: audience_workflow, published_at: Time.current)
      create(:installment_rule, installment: audience_installment, delayed_delivery_time: 1.day)

      allow(ScheduleWorkflowEmailsWorker).to receive(:perform_in) # bypass :on_create call to #schedule_all_workflows

      purchase = create(:purchase, link: product, variant_attributes: [variant])

      purchase.schedule_all_workflows

      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(product_installment.id, 1, purchase.id, nil, nil)
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(seller_product_installment.id, 1, purchase.id, nil, nil)
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(seller_variant_installment.id, 1, purchase.id, nil, nil)
      expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(audience_installment.id, 1, purchase.id, nil, nil)
      expect(SendWorkflowInstallmentWorker).not_to have_enqueued_sidekiq_job(other_product_installment.id, 1, purchase.id, nil, nil)
      expect(SendWorkflowInstallmentWorker).not_to have_enqueued_sidekiq_job(other_seller_installment.id, 1, purchase.id, nil, nil)
    end
  end

  describe "#reschedule_workflow_installments" do
    before do
      product = create(:product)
      workflow = create(:workflow, seller: product.user, link: product)

      @past_installment_1 = create(:installment, link: product, workflow:, published_at: Time.current)
      create(:installment_rule, installment: @past_installment_1, delayed_delivery_time: 1.day)

      @past_installment_2 = create(:installment, link: product, workflow:, published_at: Time.current)
      create(:installment_rule, installment: @past_installment_2, delayed_delivery_time: 3.days)

      @future_installment = create(:installment, link: product, workflow:, published_at: Time.current)
      create(:installment_rule, installment: @future_installment, delayed_delivery_time: 5.days)

      @purchase = create(:purchase, link: product, created_at: 4.days.ago)
    end

    context "when it is a quick unsubscribe and resubscribe in less than a minute" do
      it "does not reschedule any workflow installments" do
        unsubscribed_interval = 30.seconds

        travel_to(@purchase.created_at + unsubscribed_interval) do
          expect_any_instance_of(Purchase).to_not receive(:all_workflows)

          @purchase.reschedule_workflow_installments(send_delay: unsubscribed_interval)

          expect(SendWorkflowInstallmentWorker).to_not have_enqueued_sidekiq_job(@past_installment_1.id, 1, @purchase.id, nil)
          expect(SendWorkflowInstallmentWorker).to_not have_enqueued_sidekiq_job(@past_installment_2.id, 1, @purchase.id, nil)
          expect(SendWorkflowInstallmentWorker).to_not have_enqueued_sidekiq_job(@future_installment.id, 1, @purchase.id, nil)
        end
      end
    end

    context "when resubscribed after 1 hour and did not miss any workflow installments" do
      it "does not reschedule the workflow installments" do
        unsubscribed_interval = 1.hour

        travel_to(@purchase.created_at + unsubscribed_interval) do
          expect_any_instance_of(Purchase).to receive(:all_workflows).and_call_original

          @purchase.reschedule_workflow_installments(send_delay: unsubscribed_interval)

          expect(SendWorkflowInstallmentWorker).to_not have_enqueued_sidekiq_job(@past_installment_1.id, 1, @purchase.id, nil)
          expect(SendWorkflowInstallmentWorker).to_not have_enqueued_sidekiq_job(@past_installment_2.id, 1, @purchase.id, nil)
          expect(SendWorkflowInstallmentWorker).to_not have_enqueued_sidekiq_job(@future_installment.id, 1, @purchase.id, nil)
        end
      end
    end

    context "when resubscribed after 4 days and missed workflow installments" do
      it "reschedules all non-abandoned cart workflow installments in the future" do
        unsubscribed_interval = 4.days

        abandoned_cart_workflow = create(:abandoned_cart_workflow, published_at: Time.current, seller_id: @purchase.seller_id, bought_products: [@purchase.link.unique_permalink])
        abandoned_cart_workflow_installment = abandoned_cart_workflow.installments.sole
        abandoned_cart_workflow_installment_rule = create(:installment_rule, installment: abandoned_cart_workflow_installment, time_period: "hour", delayed_delivery_time: 24.hours)

        travel_to(@purchase.created_at + unsubscribed_interval) do
          expect_any_instance_of(Purchase).to receive(:all_workflows).and_call_original

          @purchase.reschedule_workflow_installments(send_delay: unsubscribed_interval)

          expect(SendWorkflowInstallmentWorker.jobs.size).to eq(3)
          expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@past_installment_1.id, 1, @purchase.id, nil)
          expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@past_installment_2.id, 1, @purchase.id, nil)
          expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@future_installment.id, 1, @purchase.id, nil)
          expect(SendWorkflowInstallmentWorker).to_not have_enqueued_sidekiq_job(abandoned_cart_workflow_installment.id, abandoned_cart_workflow_installment_rule.version, @purchase.id, nil)
        end
      end
    end
  end
end
