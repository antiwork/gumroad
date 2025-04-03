# frozen_string_literal: true

require "spec_helper"

describe Purchase::Searchable do
  before do
    travel_to(Date.new(2019, 1, 1))
  end

  describe "#indexed_json" do
    before do
      @product = create(:product, name: "My Product", user: create(:named_user))
      @purchase = create(:purchase,
                         :with_license,
                         email: "buyer1@gmail.com",
                         full_name: "Joe Buyer",
                         chargeback_date: Time.utc(2019, 1, 2),
                         is_gift_receiver_purchase: true,
                         is_multi_buy: true,
                         link: @product,
                         ip_country: "Spain",
                         variant_attributes: create_list(:variant, 2, variant_category: create(:variant_category, link: @product)),
                         tax_cents: 29,
                         card_type: "paypal",
                         card_visual: "buyer1@paypal.com",
                         purchaser: create(:user)
      )
    end

    it "includes all fields" do
      json = @purchase.as_indexed_json

      expect(json).to eq(
        "id" => @purchase.id,
        "can_contact" => true,
        "chargeback_date" => "2019-01-02T00:00:00Z",
        "country_or_ip_country" => "Spain",
        "created_at" => "2019-01-01T00:00:00Z",
        "latest_charge_date" => nil,
        "email" => "buyer1@gmail.com",
        "email_domain" => "gmail.com",
        "paypal_email" => "buyer1@paypal.com",
        "fee_cents" => 93, # 100 * 0.129 + 50 + 30
        "full_name" => "Joe Buyer",
        "not_chargedback_or_chargedback_reversed" => false,
        "not_refunded_except_subscriptions" => true,
        "not_subscription_or_original_subscription_purchase" => true,
        "successful_authorization_or_without_preorder" => true,
        "price_cents" => 100,
        "purchase_state" => "successful",
        "amount_refunded_cents" => 0,
        "fee_refunded_cents" => 0,
        "tax_refunded_cents" => 0,
        "selected_flags" => ["is_multi_buy", "is_gift_receiver_purchase"],
        "stripe_refunded" => false,
        "tax_cents" => 29,
        "monthly_recurring_revenue" => nil,
        "ip_country" => "Spain",
        "ip_state" => nil,
        "referrer_domain" => "direct",
        "variant_ids" => @purchase.variant_attributes.ids,
        "product_ids_from_same_seller_purchased_by_purchaser" => [@purchase.link_id],
        "variant_ids_from_same_seller_purchased_by_purchaser" => @purchase.variant_attributes.ids,
        "affiliate_credit_id" => nil,
        "affiliate_credit_affiliate_user_id" => nil,
        "affiliate_credit_amount_cents" => nil,
        "affiliate_credit_fee_cents" => nil,
        "affiliate_credit_amount_partially_refunded_cents" => nil,
        "affiliate_credit_fee_partially_refunded_cents" => nil,
        "product_id" => @product.id,
        "product_unique_permalink" => @product.unique_permalink,
        "product_name" => @product.name,
        "product_description" => @product.plaintext_description,
        "seller_id" => @purchase.seller.id,
        "seller_name" => @purchase.seller.name,
        "purchaser_id" => @purchase.purchaser.id,
        "subscription_id" => nil,
        "subscription_cancelled_at" => nil,
        "subscription_deactivated_at" => nil,
        "taxonomy_id" => nil,
        "license_serial" => @purchase.license.serial,
      )

      @product.default_price.update!(recurrence: "yearly")
      @purchase.subscription = create(:subscription, link: @product, cancelled_at: Time.utc(2018, 1, 1), deactivated_at: Time.utc(2018, 1, 1))
      @purchase.is_original_subscription_purchase = true
      @purchase.save!
      json = @purchase.as_indexed_json
      expect(json).to include(
        "subscription_id" => @purchase.subscription.id,
        "subscription_cancelled_at" => "2018-01-01T00:00:00Z",
        "subscription_deactivated_at" => "2018-01-01T00:00:00Z",
        "monthly_recurring_revenue" => 100.0 / 12,
        "not_refunded_except_subscriptions" => true,
        "not_subscription_or_original_subscription_purchase" => true,
      )

      @purchase.is_original_subscription_purchase = false
      original_subscription_purchase = create(:purchase, is_original_subscription_purchase: true, subscription: @purchase.subscription)
      @purchase.save!
      json = @purchase.as_indexed_json
      expect(json).to include(
        "not_refunded_except_subscriptions" => true,
        "not_subscription_or_original_subscription_purchase" => false
      )
      original_subscription_purchase.delete

      @purchase.subscription = nil
      @purchase.stripe_refunded = true
      @purchase.save!
      json = @purchase.as_indexed_json
      expect(json).to include(
        "stripe_refunded" => true,
        "not_refunded_except_subscriptions" => false,
        "not_subscription_or_original_subscription_purchase" => true
      )

      @purchase.stripe_refunded = false
      @purchase.save!
      json = @purchase.as_indexed_json
      expect(json).to include(
        "stripe_refunded" => false,
        "not_refunded_except_subscriptions" => true,
      )

      @purchase.chargeback_reversed = true
      @purchase.save!
      json = @purchase.as_indexed_json
      expect(json["not_chargedback_or_chargedback_reversed"]).to eq(true)

      @purchase.chargeback_date = nil
      @purchase.chargeback_reversed = false
      @purchase.save!
      json = @purchase.as_indexed_json
      expect(json["not_chargedback_or_chargedback_reversed"]).to eq(true)

      create(:refund, purchase: @purchase, amount_cents: 10, fee_cents: 1, creator_tax_cents: 3)
      create(:refund, purchase: @purchase, amount_cents: 20, fee_cents: 2, creator_tax_cents: 6)
      json = @purchase.as_indexed_json
      expect(json["amount_refunded_cents"]).to eq(30)
      expect(json["fee_refunded_cents"]).to eq(3)
      expect(json["tax_refunded_cents"]).to eq(9)

      affiliate_credit = create(:affiliate_credit,
                                purchase: @purchase,
                                amount_cents: 123,
                                fee_cents: 15,
                                affiliate_user: create(:user),
      )
      create(:affiliate_partial_refund, affiliate_credit:, amount_cents: 11, fee_cents: 2)
      create(:affiliate_partial_refund, affiliate_credit:, amount_cents: 22, fee_cents: 4)
      json = @purchase.reload.as_indexed_json
      expect(json).to include(
        "affiliate_credit_id" => affiliate_credit.id,
        "affiliate_credit_affiliate_user_id" => affiliate_credit.affiliate_user.id,
        "affiliate_credit_amount_cents" => 123,
        "affiliate_credit_fee_cents" => 15,
        "affiliate_credit_amount_partially_refunded_cents" => 33,
        "affiliate_credit_fee_partially_refunded_cents" => 6,
      )

      product_2 = create(:product, user: @purchase.seller)
      purchase_2 = create(:purchase,
                          seller: @purchase.seller,
                          email: @purchase.email,
                          link: product_2,
                          variant_attributes: [create(:variant, variant_category: create(:variant_category, link: product_2))],
      )
      purchase_3 = create(:purchase,
                          seller: @purchase.seller,
                          link: product_2,
                          variant_attributes: [create(:variant, variant_category: create(:variant_category, link: product_2))],
      )
      json_1 = @purchase.as_indexed_json
      json_2 = purchase_2.as_indexed_json
      json_3 = purchase_3.as_indexed_json
      expect(json_1["product_ids_from_same_seller_purchased_by_purchaser"]).to match_array([@product.id, product_2.id])
      expect(json_2["product_ids_from_same_seller_purchased_by_purchaser"]).to match_array([@product.id, product_2.id])
      expect(json_3["product_ids_from_same_seller_purchased_by_purchaser"]).to match_array([product_2.id])
      expect(json_1["variant_ids_from_same_seller_purchased_by_purchaser"]).to match_array(@purchase.variant_attributes.ids + purchase_2.variant_attributes.ids)
      expect(json_2["variant_ids_from_same_seller_purchased_by_purchaser"]).to match_array(@purchase.variant_attributes.ids + purchase_2.variant_attributes.ids)
      expect(json_3["variant_ids_from_same_seller_purchased_by_purchaser"]).to match_array(purchase_3.variant_attributes.ids)

      @purchase.subscription = create(:subscription)
      @purchase.is_original_subscription_purchase = true
      @purchase.save!
      purchase_2.purchase_state = "in_progress"
      purchase_2.subscription = @purchase.subscription
      purchase_2.created_at = Time.utc(2020, 6, 6)
      purchase_2.save!
      json = @purchase.as_indexed_json
      expect(json["latest_charge_date"]).to eq("2019-01-01T00:00:00Z")

      purchase_2.purchase_state = "successful"
      purchase_2.save!
      json = @purchase.as_indexed_json
      expect(json["latest_charge_date"]).to eq("2020-06-06T00:00:00Z")

      @purchase.update!(preorder: create(:preorder))
      json = @purchase.as_indexed_json
      expect(json["successful_authorization_or_without_preorder"]).to eq(false)

      @purchase.update!(purchase_state: "preorder_authorization_successful")
      json = @purchase.as_indexed_json
      expect(json["successful_authorization_or_without_preorder"]).to eq(true)

      @purchase.update!(purchase_state: "preorder_concluded_unsuccessfully")
      json = @purchase.as_indexed_json
      expect(json["successful_authorization_or_without_preorder"]).to eq(false)

      @purchase.update!(purchase_state: "preorder_concluded_successfully")
      json = @purchase.as_indexed_json
      expect(json["successful_authorization_or_without_preorder"]).to eq(true)

      @purchase.update!(purchase_state: "failed")
      json = @purchase.as_indexed_json
      expect(json["successful_authorization_or_without_preorder"]).to eq(false)

      @purchase.update!(referrer: "https://twitter.com/gumroad")
      json = @purchase.as_indexed_json
      expect(json["referrer_domain"]).to eq("twitter.com")

      @purchase.was_product_recommended = true
      @purchase.save!
      json = @purchase.as_indexed_json
      expect(json["referrer_domain"]).to eq("recommended_by_gumroad")

      @purchase.update!(ip_country: "United States", ip_state: "CA")
      json = @purchase.as_indexed_json
      expect(json).to include(
        "ip_country" => "United States",
        "ip_state" => "CA"
      )

      @purchase.update!(email: "name@yahoo.com")
      json = @purchase.as_indexed_json
      expect(json).to include(
        "email" => "name@yahoo.com",
        "email_domain" => "yahoo.com"
      )

      @product.update!(taxonomy: create(:taxonomy))
      json = @purchase.reload.as_indexed_json
      expect(json).to include(
        "taxonomy_id" => @product.taxonomy.id
      )
    end

    it "supports only returning specific fields" do
      json = @purchase.as_indexed_json(only: ["full_name", "product_id"])
      expect(json).to eq(
        "full_name" => "Joe Buyer",
        "product_id" => @product.id
      )
    end
  end

  describe "Subscription Callbacks" do
    before do
      @subscription = create(:subscription)
      @purchase_1 = create(:purchase, subscription: @subscription, is_original_subscription_purchase: true)
      @purchase_2 = create(:purchase, subscription: @subscription)
      ElasticsearchIndexerWorker.jobs.clear
    end

    it "updates related purchases when deactivated_at changes" do
      @subscription.deactivate!

      expect(ElasticsearchIndexerWorker.jobs.size).to eq(2)
      expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("update", "record_id" => @purchase_1.id, "class_name" => "Purchase", "fields" => ["subscription_deactivated_at"])
      expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("update", "record_id" => @purchase_2.id, "class_name" => "Purchase", "fields" => ["subscription_deactivated_at"])
    end

    it "does not update related purchases when unrelated attributes changes" do
      @subscription.charge_occurrence_count = 123
      @subscription.save!

      expect(ElasticsearchIndexerWorker.jobs.size).to eq(0)
    end
  end

  describe "RelatedPurchase Callbacks" do
    before do
      @seller = create(:user)
      @product = create(:product, user: @seller)
      @variant_1, @variant_2 = create_list(:variant, 2, variant_category: create(:variant_category, link: @product))
      @purchase = create(:purchase, link: @product, variant_attributes: [@variant_1])
      index_model_records(Purchase)
      ElasticsearchIndexerWorker.jobs.clear
    end

    context "when creating successful purchase" do
      before do
        @product_2 = create(:product, user: @seller)
        @purchase_2 = create(:purchase, seller: @seller, link: @product_2, email: @purchase.email)
      end

      it "queues update_by_query for related purchases documents" do
        expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job(*update_related_purchases_job_params(@purchase_2))
      end

      it "updates related purchases documents", :sidekiq_inline, :elasticsearch_wait_for_refresh do
        purchase_1_doc = get_document_attributes(@purchase)
        expect(purchase_1_doc["product_ids_from_same_seller_purchased_by_purchaser"]).to eq([@product.id, @product_2.id])
        expect(purchase_1_doc["variant_ids_from_same_seller_purchased_by_purchaser"]).to eq([@variant_1.id])
      end
    end

    context "when creating non-successful purchase" do
      before do
        product_2 = create(:product, user: @seller)
        @purchase_2 = create(:purchase_in_progress, seller: @seller, link: product_2, email: @purchase.email)
        @purchase_3 = create(:failed_purchase, seller: @seller, link: product_2, email: @purchase.email)
      end

      it "does not queue update_by_query job" do
        expect(ElasticsearchIndexerWorker).not_to have_enqueued_sidekiq_job(*update_related_purchases_job_params(@purchase_2))
        expect(ElasticsearchIndexerWorker).not_to have_enqueued_sidekiq_job(*update_related_purchases_job_params(@purchase_3))
      end
    end

    context "when transitioning purchase to successful" do
      before do
        @product_2 = create(:product, user: @seller)
        @purchase_2 = create(:purchase_in_progress, seller: @seller, link: @product_2, email: @purchase.email)
        @purchase_2.mark_successful!
      end

      it "queues update_by_query for related purchases documents" do
        expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job(*update_related_purchases_job_params(@purchase_2))
      end

      it "updates related purchases documents", :sidekiq_inline, :elasticsearch_wait_for_refresh do
        purchase_1_doc = get_document_attributes(@purchase)
        expect(purchase_1_doc["product_ids_from_same_seller_purchased_by_purchaser"]).to eq([@product.id, @product_2.id])
        expect(purchase_1_doc["variant_ids_from_same_seller_purchased_by_purchaser"]).to eq([@variant_1.id])
      end
    end

    context "when updating an irrelevant attribute" do
      before do
        @purchase.update!(can_contact: false)
      end

      it "does not queue update_by_query job" do
        expect(ElasticsearchIndexerWorker).not_to have_enqueued_sidekiq_job(*update_related_purchases_job_params(@purchase))
      end
    end

    context "when creating a subscription purchase" do
      it "queues an update to related purchase's documents" do
        subscription = create(:subscription)
        @purchase.subscription = subscription
        @purchase.is_original_subscription_purchase = true
        @purchase.save!
        ElasticsearchIndexerWorker.jobs.clear

        create(:purchase, seller: @seller, link: @product, email: @purchase.email, subscription:)
        expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("update", "record_id" => @purchase.id, "class_name" => "Purchase", "fields" => ["latest_charge_date"])
      end
    end

    context "with a subscription's new purchase" do
      before do
        subscription = create(:subscription)
        @purchase.subscription = subscription
        @purchase.is_original_subscription_purchase = true
        @purchase.save!
        @purchase_2 = create(:purchase, seller: @seller, link: @product, email: @purchase.email, subscription:, purchase_state: "in_progress")
        ElasticsearchIndexerWorker.jobs.clear
      end

      context "when updating purchase_state" do
        before do
          @purchase_2.update!(purchase_state: "successful")
        end

        it "queues an update to related purchases' documents" do
          expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("update", "record_id" => @purchase.id, "class_name" => "Purchase", "fields" => ["latest_charge_date"])
        end
      end

      context "when updating an irrelevant attribute" do
        before do
          @purchase_2.update!(can_contact: false)
        end

        it "does not queue an update to related purchases' documents" do
          expect(ElasticsearchIndexerWorker).not_to have_enqueued_sidekiq_job("update", "record_id" => @purchase.id, "class_name" => "Purchase", "fields" => ["latest_charge_date"])
        end
      end

      context "when updating an irrelevant attribute on a successful purchase" do
        before do
          @purchase_2.update!(purchase_state: "successful")
          ElasticsearchIndexerWorker.jobs.clear
          @purchase_2.update!(can_contact: false)
        end

        it "does not queue an update to related purchases' documents" do
          expect(ElasticsearchIndexerWorker).not_to have_enqueued_sidekiq_job("update", "record_id" => @purchase.id, "class_name" => "Purchase", "fields" => ["latest_charge_date"])
        end
      end
    end
  end

  describe "VariantAttribute Callbacks" do
    describe ".variants_changed" do
      before do
        product = create(:product)
        category = create(:variant_category, link: product)
        @variant_1, @variant_2 = create_list(:variant, 2, variant_category: category)

        @purchase_1, @purchase_2 = create_list(:purchase, 2,
                                               link: product,
                                               email: "joe@gmail.com",
                                               variant_attributes: [@variant_1]
        )

        Purchase::VariantUpdaterService.new(
          purchase: @purchase_2,
          variant_id: @variant_2.external_id,
          quantity: @purchase_2.quantity,
        ).perform
      end

      it "queues udpate for purchase, and related purchases" do
        expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job(
          "update",
          "record_id" => @purchase_2.id,
          "class_name" => "Purchase",
          "fields" => ["variant_ids", "variant_ids_from_same_seller_purchased_by_purchaser"]
        )
        expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job(
          "update_by_query",
          "source_record_id" => @purchase_2.id,
          "class_name" => "Purchase",
          "fields" => ["variant_ids_from_same_seller_purchased_by_purchaser"],
          "query" => PurchaseSearchService.new(
            seller: @purchase_2.seller,
            email: @purchase_2.email,
            exclude_purchase: @purchase_2.id
          ).body[:query]
        )
      end

      it "updates related purchases documents", :sidekiq_inline, :elasticsearch_wait_for_refresh do
        purchase_1_doc = get_document_attributes(@purchase_1)
        expect(purchase_1_doc["variant_ids"]).to eq([@variant_1.id])
        expect(purchase_1_doc["variant_ids_from_same_seller_purchased_by_purchaser"]).to eq([@variant_1.id, @variant_2.id])
        purchase_2_doc = get_document_attributes(@purchase_2)
        expect(purchase_2_doc["variant_ids"]).to eq([@variant_2.id])
        expect(purchase_2_doc["variant_ids_from_same_seller_purchased_by_purchaser"]).to eq([@variant_1.id, @variant_2.id])
      end
    end
  end

  describe "AffiliateCredit Callbacks" do
    before do
      @purchase = create(:purchase)
      ElasticsearchIndexerWorker.jobs.clear
    end

    context "when affiliate_credit is created" do
      it "updates purchase document" do
        create(:affiliate_credit, purchase: @purchase, amount_cents: 123, fee_cents: 15)

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(1)
        expect(ElasticsearchIndexerWorker).to \
          have_enqueued_sidekiq_job("update", "record_id" => @purchase.id, "class_name" => "Purchase", "fields" => %w[
                                      affiliate_credit_id
                                      affiliate_credit_amount_cents
                                      affiliate_credit_affiliate_user_id
                                      affiliate_credit_fee_cents
                                    ])
      end
    end

    context "when affiliate_credit is updated" do
      before do
        @affiliate_credit = create(:affiliate_credit, purchase: @purchase, amount_cents: 123, fee_cents: 15)
        @balances = create_list(:balance, 3)
        ElasticsearchIndexerWorker.jobs.clear
      end

      it "updates purchase document" do
        @affiliate_credit.update!(amount_cents: 55, fee_cents: 10)

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(1)
        expect(ElasticsearchIndexerWorker).to \
          have_enqueued_sidekiq_job("update", "record_id" => @purchase.id, "class_name" => "Purchase", "fields" => %w[affiliate_credit_amount_cents affiliate_credit_fee_cents])
      end
    end
  end

  describe "Product Callbacks" do
    it "enqueues update_by_query job when taxonomy is updated" do
      product = create(:product)
      purchase = create(:purchase, link: product)
      product.update!(taxonomy: create(:taxonomy))
      expect(ElasticsearchIndexerWorker).to \
        have_enqueued_sidekiq_job("update_by_query", "source_record_id" => purchase.id, "class_name" => "Purchase", "fields" => %w[taxonomy_id], "query" => PurchaseSearchService.new(product:).body[:query])
    end

    it "does not enqueue update_by_query job when product has no sales" do
      product = create(:product)
      ElasticsearchIndexerWorker.jobs.clear

      product.update!(taxonomy: create(:taxonomy))
      expect(ElasticsearchIndexerWorker.jobs.size).to eq(0)
    end

    it "updates the sales' Elasticsearch documents when the taxonomy is changed", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      taxonomies = create_list(:taxonomy, 2)
      product = create(:product, taxonomy: taxonomies.first)
      purchases = create_list(:purchase, 2, link: product)
      expect(get_document_attributes(purchases.first)["taxonomy_id"]).to eq(taxonomies.first.id)
      expect(get_document_attributes(purchases.last)["taxonomy_id"]).to eq(taxonomies.first.id)

      product.update!(taxonomy: taxonomies.last)
      expect(get_document_attributes(purchases.first)["taxonomy_id"]).to eq(taxonomies.last.id)
      expect(get_document_attributes(purchases.last)["taxonomy_id"]).to eq(taxonomies.last.id)
    end
  end

  context "updating a purchase", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    it "sets the subscription id" do
      subscription = create(:subscription)
      purchase = create(:purchase)
      subscription.purchases << purchase

      expect(get_document_attributes(purchase)["subscription_id"]).to eq(subscription.id)
    end
  end

  def get_document_attributes(record)
    EsClient.get(index: Purchase.index_name, id: record.id, ignore: 404)["_source"]
  end

  def update_related_purchases_job_params(purchase)
    [
      "update_by_query",
      {
        "source_record_id" => purchase.id,
        "class_name" => "Purchase",
        "fields" => ["product_ids_from_same_seller_purchased_by_purchaser", "variant_ids_from_same_seller_purchased_by_purchaser"],
        "query" => PurchaseSearchService.new(
          seller: purchase.seller,
          email: purchase.email,
          exclude_purchase: purchase.id
        ).body[:query]
      }
    ]
  end
end
