# frozen_string_literal: true

require "spec_helper"

describe PurchaseSearchService do
  describe "#process" do
    it "can filter by seller" do
      purchase_1 = create(:purchase)
      purchase_2 = create(:purchase, link: purchase_1.link) # same seller as purchase_1
      seller_1 = purchase_1.seller
      purchase_3 = create(:purchase)
      seller_2 = purchase_3.seller
      create(:purchase)
      index_model_records(Purchase)

      expect(get_records(seller: seller_1)).to match_array([purchase_1, purchase_2])
      expect(get_records(seller: [seller_1, seller_2.id])).to match_array([purchase_1, purchase_2, purchase_3])
    end

    it "can filter by buyer" do
      purchase_1 = create(:purchase, purchaser: create(:user))
      purchaser_1 = purchase_1.purchaser
      purchase_2 = create(:purchase, purchaser: purchaser_1)
      purchase_3 = create(:purchase, purchaser: create(:user))
      purchaser_2 = purchase_3.purchaser
      create(:purchase, purchaser: create(:user))
      index_model_records(Purchase)

      expect(get_records(purchaser: purchaser_1)).to match_array([purchase_1, purchase_2])
      expect(get_records(purchaser: [purchaser_1, purchaser_2.id])).to match_array([purchase_1, purchase_2, purchase_3])
    end

    it "can filter by product, and exclude product" do
      product_1 = create(:product)
      purchase_1, purchase_2 = create_list(:purchase, 2, link: product_1)
      product_2 = create(:product)
      purchase_3 = create(:purchase, link: product_2)
      index_model_records(Purchase)

      expect(get_records(product: product_1)).to match_array([purchase_1, purchase_2])
      expect(get_records(product: [product_1, product_2.id])).to match_array([purchase_1, purchase_2, purchase_3])
      expect(get_records(exclude_product: product_1)).to match_array([purchase_3])
      expect(get_records(exclude_product: [product_1, product_2.id])).to match_array([])
    end

    it "can filter by variant, and exclude variant" do
      product = create(:product)
      category_1, category_2 = create_list(:variant_category, 2, link: product)
      variant_1, variant_2, variant_3 = create_list(:variant, 3, variant_category: category_1)
      variant_4 = create(:variant, variant_category: category_2)
      purchase_1 = create(:purchase, link: product, variant_attributes: [variant_1])
      purchase_2 = create(:purchase, link: product, variant_attributes: [variant_2])
      purchase_3 = create(:purchase, link: product, variant_attributes: [variant_3])
      purchase_4 = create(:purchase, link: product, variant_attributes: [variant_3, variant_4])
      index_model_records(Purchase)

      expect(get_records(variant: variant_3)).to match_array([purchase_3, purchase_4])
      expect(get_records(variant: [variant_2, variant_3, variant_4.id])).to match_array([purchase_2, purchase_3, purchase_4])
      expect(get_records(exclude_variant: variant_3)).to match_array([purchase_1, purchase_2])
      expect(get_records(exclude_variant: [variant_1, variant_3.id])).to match_array([purchase_2])
    end

    it "can exclude purchasers of a product or a variant" do
      # Typical usage:
      # - Seller X needs to see which sales were made to people who didn't buy their product X.
      # - Seller X needs to see which sales of product X were made to people who didn't buy the variant Y.
      product_1 = create(:product)
      variant_category = create(:variant_category, link: product_1)
      variant_1, variant_2, variant_3 = create_list(:variant, 3, variant_category:)
      seller = product_1.user
      product_2, product_3 = create_list(:product, 2, user: seller)
      customer_1 = create(:user)
      purchase_1 = create(:purchase, link: product_1, email: customer_1.email, variant_attributes: [variant_1])
      _purchase_2 = create(:purchase, link: product_2, email: customer_1.email, purchaser: customer_1)
      _purchase_3 = create(:purchase, link: product_3, email: customer_1.email, purchaser: customer_1)
      purchase_4 = create(:purchase, link: product_1, variant_attributes: [variant_2])
      index_model_records(Purchase)

      expect(get_records(seller:, exclude_purchasers_of_product: product_1)).to match_array([])
      expect(get_records(seller:, exclude_purchasers_of_product: product_2)).to match_array([purchase_4])
      expect(get_records(seller:, exclude_purchasers_of_product: product_3)).to match_array([purchase_4])
      expect(get_records(seller:, product: product_1, exclude_purchasers_of_variant: variant_1)).to match_array([purchase_4])
      expect(get_records(seller:, product: product_1, exclude_purchasers_of_variant: variant_2)).to match_array([purchase_1])
      expect(get_records(seller:, product: product_1, exclude_purchasers_of_variant: variant_3)).to match_array([purchase_1, purchase_4])
    end

    it "can filter by affiliate user" do
      purchase_1 = create(:purchase)
      affiliate_credit_1 = create(:affiliate_credit, purchase: purchase_1)
      purchase_2 = create(:purchase)
      affiliate_credit_2 = create(:affiliate_credit, purchase: purchase_2)
      index_model_records(Purchase)

      expect(get_records(affiliate_user: affiliate_credit_1.affiliate_user)).to match_array([purchase_1])
      expect(get_records(affiliate_user: [affiliate_credit_1.affiliate_user, affiliate_credit_2.affiliate_user.id])).to match_array([purchase_1, purchase_2])
    end

    it "can filter by revenue sharing user" do
      seller_purchase_1 = create(:purchase)
      seller_purchase_2 = create(:purchase, link: seller_purchase_1.link)
      user_1 = seller_purchase_1.seller
      seller_purchase_3 = create(:purchase)
      user_2 = seller_purchase_3.seller
      create(:purchase)

      affiliate_purchase_1 = create(:purchase)
      create(:affiliate_credit, purchase: affiliate_purchase_1, affiliate_user: user_1)
      affiliate_purchase_2 = create(:purchase)
      create(:affiliate_credit, purchase: affiliate_purchase_2, affiliate_user: user_2)
      create(:affiliate_credit)

      user_1_purchases = [seller_purchase_1, seller_purchase_2, affiliate_purchase_1]
      user_2_purchases = [seller_purchase_3, affiliate_purchase_2]

      index_model_records(Purchase)

      expect(get_records(revenue_sharing_user: user_1)).to match_array(user_1_purchases)
      expect(get_records(revenue_sharing_user: user_2)).to match_array(user_2_purchases)
      expect(get_records(revenue_sharing_user: [user_1, user_2])).to match_array(user_1_purchases + user_2_purchases)
    end

    it "can exclude purchases" do
      purchase_1, purchase_2 = create_list(:purchase, 2)
      index_model_records(Purchase)

      expect(get_records(exclude_purchase: purchase_1)).to match_array([purchase_2])
      expect(get_records(exclude_purchase: [purchase_1, purchase_2.id])).to match_array([])
    end

    it "can filter by multiple variants and products" do
      product_1, product_2, product_3 = create_list(:product, 3)
      category_1 = create(:variant_category, link: product_1)
      category_2 = create(:variant_category, link: product_2)
      variant_1, variant_2 = create_list(:variant, 2, variant_category: category_1)
      variant_3, variant_4 = create_list(:variant, 2, variant_category: category_2)
      purchase_1 = create(:purchase, link: product_1, variant_attributes: [variant_1])
      purchase_2 = create(:purchase, link: product_1, variant_attributes: [variant_2])
      purchase_3 = create(:purchase, link: product_2, variant_attributes: [variant_3])
      purchase_4 = create(:purchase, link: product_2, variant_attributes: [variant_4])
      purchase_5 = create(:purchase, link: product_3)
      index_model_records(Purchase)

      expect(get_records(any_products_or_variants: { variants: [variant_1, variant_3] })).to match_array([purchase_1, purchase_3])
      expect(get_records(any_products_or_variants: { variants: variant_2, products: [product_3] })).to match_array([purchase_2, purchase_5])
      expect(get_records(any_products_or_variants: { variants: variant_4, products: [product_1, product_2] })).to match_array([purchase_1, purchase_2, purchase_3, purchase_4])
    end

    it "can exclude non-original subscription and archived original subscription purchases" do
      purchase_1 = create(:membership_purchase, created_at: 2.days.ago)
      _purchase_2 = purchase_1.subscription.charge!
      purchase_3 = create(:membership_purchase, created_at: 2.days.ago)
      _purchase_4 = purchase_3.subscription.charge!
      purchase_5 = create(:purchase)
      _purchase_6 = create(:membership_purchase, created_at: 3.days.ago, is_archived_original_subscription_purchase: true)
      index_model_records(Purchase)

      expect(get_records(exclude_non_original_subscription_purchases: true)).to match_array([purchase_1, purchase_3, purchase_5])
    end

    it "can exclude not_charged purchases that are not free trials" do
      purchase = create(:free_trial_membership_purchase)
      create(:purchase, purchase_state: "not_charged")
      index_model_records(Purchase)

      expect(get_records(exclude_not_charged_non_free_trial_purchases: true)).to match_array([purchase])
    end

    it "can exclude deactivated subscriptions" do
      purchase_1 = create(:membership_purchase, created_at: 2.days.ago)
      purchase_2 = create(:membership_purchase, created_at: 2.days.ago)
      subscription = purchase_2.subscription
      subscription.deactivate!
      index_model_records(Purchase)

      expect(get_records(exclude_deactivated_subscriptions: true)).to match_array([purchase_1])
    end

    it "can exclude cancelled subscriptions, or pending cancellation" do
      purchase_1 = create(:membership_purchase)
      create(:membership_purchase).subscription.update!(cancelled_at: 2.days.ago)
      create(:membership_purchase).subscription.update!(cancelled_at: 2.days.from_now)
      index_model_records(Purchase)

      expect(get_records(exclude_cancelled_or_pending_cancellation_subscriptions: true)).to match_array([purchase_1])
    end

    it "can exclude refunded" do
      purchase_1 = create(:purchase, stripe_refunded: nil)
      purchase_2 = create(:purchase, stripe_refunded: false)
      _purchase_3 = create(:purchase, stripe_refunded: true)
      index_model_records(Purchase)

      expect(get_records(exclude_refunded: true)).to match_array([purchase_1, purchase_2])
    end

    it "can exclude refunded-except-subscriptions" do
      purchase_1 = create(:purchase)
      _purchase_2 = create(:purchase, stripe_refunded: true)
      purchase_3 = create(:membership_purchase, stripe_refunded: true)
      index_model_records(Purchase)

      expect(get_records(exclude_refunded_except_subscriptions: true)).to match_array([purchase_1, purchase_3])
    end

    it "can exclude unreversed charged back" do
      purchase_1 = create(:purchase)
      _purchase_2 = create(:purchase, chargeback_date: Time.current)
      purchase_3 = create(:purchase, chargeback_date: Time.current, chargeback_reversed: true)
      index_model_records(Purchase)

      expect(get_records(exclude_unreversed_chargedback: true)).to match_array([purchase_1, purchase_3])
    end

    it "can exclude purchases from buyers that can't be contacted" do
      purchase_1 = create(:purchase)
      _purchase_2 = create(:purchase, can_contact: false)
      index_model_records(Purchase)

      expect(get_records(exclude_cant_contact: true)).to match_array([purchase_1])
    end

    it "can exclude gifters or giftees" do
      purchase_1 = create(:purchase)
      gift = create(:gift)
      product = gift.link
      purchase_2 = create(:purchase, link: product, is_gift_sender_purchase: true)
      purchase_3 = create(:purchase, link: product, is_gift_receiver_purchase: true)
      index_model_records(Purchase)

      expect(get_records(exclude_gifters: true)).to match_array([purchase_1, purchase_3])
      expect(get_records(exclude_giftees: true)).to match_array([purchase_1, purchase_2])
    end

    it "can exclude non-successful authorization purchases" do
      # Without preorder
      purchase_1 = create(:purchase)
      purchase_2 = create(:failed_purchase)
      # With preorder which ended up concluding successfully
      preorder = create(:preorder)
      product = preorder.link
      purchase_3 = create(:purchase, purchase_state: "preorder_concluded_successfully", link: product)
      purchase_3.update!(preorder:)
      create(:failed_purchase, link: product, preorder:) # purchase_4
      create(:purchase, link: product, preorder:) # purchase_5
      # With preorder which didn't conclude yet
      preorder = create(:preorder)
      product = preorder.link
      purchase_6 = create(:preorder_authorization_purchase, link: product)
      purchase_6.update!(preorder:)
      create(:failed_purchase, link: product, preorder:) # purchase_7
      # With failed preorder
      preorder = create(:preorder)
      purchase_8 = create(:purchase, purchase_state: "preorder_authorization_failed", link: preorder.link)
      purchase_8.update!(preorder:)
      # With preorder which failed to conclude
      preorder = create(:preorder)
      purchase_9 = create(:purchase, purchase_state: "preorder_concluded_unsuccessfully", link: preorder.link)
      purchase_9.update!(preorder:)
      index_model_records(Purchase)

      expect(get_records(exclude_non_successful_preorder_authorizations: true)).to match_array([
                                                                                                 purchase_1, purchase_2, purchase_3, purchase_6
                                                                                               ])
    end

    it "can filter by price ranges" do
      purchase_1 = create(:purchase, price_cents: 0)
      purchase_2 = create(:purchase, price_cents: 60)
      purchase_3 = create(:purchase, price_cents: 100)
      purchase_4 = create(:purchase, price_cents: 101)
      index_model_records(Purchase)

      expect(get_records(price_greater_than: 0)).to match_array([purchase_2, purchase_3, purchase_4])
      expect(get_records(price_greater_than: 100)).to match_array([purchase_4])
      expect(get_records(price_less_than: 0)).to match_array([])
      expect(get_records(price_less_than: 100)).to match_array([purchase_1, purchase_2])
      expect(get_records(price_greater_than: 40, price_less_than: 100)).to match_array([purchase_2])
    end

    it "can filter by date ranges" do
      travel_to(Time.current)

      purchase_1 = create(:purchase, created_at: 15.days.ago)
      purchase_2 = create(:purchase, created_at: 7.days.ago)
      purchase_3 = create(:purchase, created_at: 3.days.ago)
      index_model_records(Purchase)

      expect(get_records(created_after: 9.days.ago)).to match_array([purchase_2, purchase_3])
      expect(get_records(created_after: 1.day.ago)).to match_array([])
      expect(get_records(created_before: 20.days.ago)).to match_array([])
      expect(get_records(created_before: 9.days.ago)).to match_array([purchase_1])
      expect(get_records(created_after: 8.days.ago, created_before: 6.days.ago)).to match_array([purchase_2])

      expect(get_records(created_after: purchase_1.created_at)).not_to include(purchase_1)
      expect(get_records(created_on_or_after: purchase_1.created_at)).to match_array([purchase_1, purchase_2, purchase_3])
      expect(get_records(created_before: purchase_1.created_at)).not_to include(purchase_1)
      expect(get_records(created_on_or_before: purchase_1.created_at)).to eq([purchase_1])
    end

    it "can filter by country" do
      purchase_1 = create(:physical_purchase)
      purchase_2 = create(:physical_purchase, country: nil, ip_country: "Mexico")
      purchase_3 = create(:physical_purchase, country: "South Korea", ip_country: "South Korea")
      purchase_4 = create(:physical_purchase, country: "Korea, Republic of", ip_country: "South Korea")
      index_model_records(Purchase)

      expect(get_records(country: "United States")).to match_array([purchase_1])
      expect(get_records(country: "Mexico")).to match_array([purchase_2])
      expect(get_records(country: ["South Korea", "Korea, Republic of"])).to match_array([purchase_3, purchase_4])
    end

    it "can filter by email" do
      purchase_1 = create(:purchase, email: "john@example.com")
      purchase_2 = create(:purchase, email: "rosalina@example.com")
      purchase_3 = create(:purchase, email: "john@example.com")
      index_model_records(Purchase)

      expect(get_records(email: "john@example.com")).to match_array([purchase_1, purchase_3])
      expect(get_records(email: "John@example.com")).to match_array([purchase_1, purchase_3])
      expect(get_records(email: "rosalina@example.com")).to match_array([purchase_2])
      # Check that we're actually doing an exact match
      expect(get_records(email: "rosalina@example")).to match_array([])
    end

    it "can filter by state" do
      purchase_1 = create(:purchase)
      purchase_2 = create(:test_purchase)
      _purchase_3 = create(:purchase_in_progress)
      purchase_4 = create(:purchase, purchase_state: "gift_receiver_purchase_successful")
      index_model_records(Purchase)

      expect(get_records(state: "successful")).to match_array([purchase_1])
      expect(get_records(state: ["successful", "test_successful"])).to match_array([purchase_1, purchase_2])
      expect(get_records(state: ["gift_receiver_purchase_successful"])).to match_array([purchase_4])
    end

    it "can filter by archival state" do
      purchase_1 = create(:purchase)
      purchase_2 = create(:purchase, is_archived: true)
      index_model_records(Purchase)

      expect(get_records).to match_array([purchase_1, purchase_2])
      expect(get_records(archived: true)).to match_array([purchase_2])
      expect(get_records(archived: false)).to match_array([purchase_1])
    end

    it "can filter by recommended state" do
      purchase_1 = create(:purchase)
      purchase_2 = create(:purchase, was_product_recommended: true)
      index_model_records(Purchase)

      expect(get_records).to match_array([purchase_1, purchase_2])
      expect(get_records(recommended: true)).to match_array([purchase_2])
      expect(get_records(recommended: false)).to match_array([purchase_1])
    end

    it "can filter by is_bundle_product_purchase" do
      purchase1 = create(:purchase, is_bundle_product_purchase: true)
      purchase2 = create(:purchase)
      index_model_records(Purchase)

      expect(get_records).to match_array([purchase1, purchase2])
      expect(get_records(exclude_bundle_product_purchases: true)).to match_array([purchase2])
      expect(get_records(exclude_bundle_product_purchases: false)).to match_array([purchase1, purchase2])
    end

    it "can filter by is_commission_completion_purchase" do
      purchase1 = create(:purchase, is_commission_completion_purchase: true)
      purchase2 = create(:purchase)
      index_model_records(Purchase)

      expect(get_records).to match_array([purchase1, purchase2])
      expect(get_records(exclude_commission_completion_purchases: true)).to match_array([purchase2])
      expect(get_records(exclude_commission_completion_purchases: false)).to match_array([purchase1, purchase2])
    end

    it "can apply some native ES params" do
      purchase_1 = create(:purchase, price_cents: 3)
      _purchase_2 = create(:purchase, price_cents: 1)
      _purchase_3 = create(:purchase, price_cents: 5)
      index_model_records(Purchase)

      response = described_class.new(sort: { price_cents: :asc }, from: 1, size: 1).process
      expect(response.results.total).to eq(3)
      expect(response.records.load).to match_array([purchase_1])
    end

    it "supports fulltext/autocomplete search as seller" do
      purchase_1 = create(:purchase, email: "xavier@loic.com", full_name: "Joelle", card_type: CardType::PAYPAL, card_visual: "xavier@paypal.com")
      purchase_2 = create(:purchase, email: "rebecca+test@victoria.com", full_name: "Jo Elizabeth")
      purchase_3 = create(:purchase, email: "rebecca.test@victoria.com", full_name: "Joelle Elizabeth")
      purchase_4 = create(:purchase, email: "rebecca@victoria.com", full_name: "Joe")
      purchase_5 = create(:purchase, email: "StevenPaulJobs@apple.com", full_name: "")
      purchase_6 = create(:purchase, :with_license)
      index_model_records(Purchase)

      expect(get_records(seller_query: "xav")).to match_array([purchase_1])
      expect(get_records(seller_query: "joel")).to match_array([purchase_1, purchase_3])
      expect(get_records(seller_query: "rebecca+test")).to match_array([purchase_2])
      expect(get_records(seller_query: "rebecca.test")).to match_array([purchase_3])
      expect(get_records(seller_query: "rebecca")).to match_array([purchase_2, purchase_3, purchase_4])
      expect(get_records(seller_query: "eliza")).to match_array([purchase_2, purchase_3])
      # test support for non-exact search
      expect(get_records(seller_query: "Joelle Elizabeth")).to match_array([purchase_1, purchase_2, purchase_3])
      # test support for exact name search
      expect(get_records(seller_query: "\"Joelle Elizabeth\"")).to match_array([purchase_3])
      # test support for exact search beyond max_ngram
      expect(get_records(seller_query: "rebecca.test@victoria.com")).to match_array([purchase_3])
      # test support for exact email search wth different case
      expect(get_records(seller_query: "Rebecca.test@victoria.com")).to match_array([purchase_3])
      expect(get_records(seller_query: "Xavier@paypal.com")).to match_array([purchase_1])
      expect(get_records(seller_query: "StevenPaulJobs@apple.com")).to match_array([purchase_5])
      expect(get_records(seller_query: "stevenpauljobs@apple.com")).to match_array([purchase_5])
      # test support for email's domain name search
      expect(get_records(seller_query: "apple.com")).to match_array([purchase_5])
      expect(get_records(seller_query: "vic")).to match_array([purchase_2, purchase_3, purchase_4])
      # test support to paypal email exact search
      expect(get_records(seller_query: "xavier@paypal.com")).to match_array([purchase_1])
      expect(get_records(seller_query: "paypal.com")).to match_array([])
      # test scoring
      expect(get_records(seller_query: "Joelle Elizabeth")).to eq([purchase_3, purchase_1, purchase_2])
      # test support for license key search
      expect(get_records(seller_query: purchase_6.license.serial)).to match_array([purchase_6])
    end

    it "supports fulltext/autocomplete search as a buyer" do
      seller_1 = create(:user, name: "Daniel Vassallo")
      product_1 = create(:product, name: "Everyone Can Build a Twitter Audience", user: seller_1, description: "Last year I left a cushy job at <strong>Amazon</strong> to work for myself.")
      product_2 = create(:product, name: "Profit and Loss", user: seller_1, description: "I will show you exactly how I'm executing my Portfolio of Small Bets strategy.")
      seller_2 = create(:user, name: "Wong Fu Productions")
      product_3 = create(:product, name: "Strangers Never Again", user: seller_2, description: "Josh and Marissa were in love a decade ago, in their early 20s, and since then, life took them in very different directions.")
      purchase_1 = create(:purchase, link: product_1)
      purchase_2 = create(:purchase, link: product_2)
      purchase_3 = create(:purchase, link: product_3)
      index_model_records(Purchase)

      # test seller's name
      expect(get_records(buyer_query: "daniel vassallo")).to match_array([purchase_1, purchase_2])
      expect(get_records(buyer_query: "daniel")).to match_array([purchase_1, purchase_2])
      expect(get_records(buyer_query: "dan")).to match_array([purchase_1, purchase_2])
      expect(get_records(buyer_query: "wong fu")).to match_array([purchase_3])
      # test product's name
      expect(get_records(buyer_query: "profit")).to match_array([purchase_2])
      # test product's description
      expect(get_records(buyer_query: "amazon")).to match_array([purchase_1])
      expect(get_records(buyer_query: "amaz")).to match_array([]) # we shouldn't auto-complete description: too large & irrelevant
      expect(get_records(buyer_query: "small bets")).to match_array([purchase_2])
      expect(get_records(buyer_query: "love")).to match_array([purchase_3])
    end
  end

  describe "#query" do
    it "is a shortcut to the query part of the request body" do
      service = described_class.new(seller: 123)
      expect(service.query).to eq(service.body[:query])
    end
  end

  describe ".search" do
    it "is a shortcut to initialization + process" do
      result_double = double
      options = { a: 1, b: 2 }
      instance_double = double(process: result_double)
      expect(described_class).to receive(:new).with(options).and_return(instance_double)
      expect(described_class.search(options)).to eq(result_double)
    end
  end

  def get_records(options = {})
    service = described_class.new(options)
    keys_and_values = deep_to_a(service.body.deep_stringify_keys).flatten
    expect(JSON.load(JSON.dump(keys_and_values))).to eq(keys_and_values) # body values must be JSON safe (no Time, etc.)
    service.process.records.load
  end

  def deep_to_a(hash)
    hash.map do |v|
      v.is_a?(Hash) || v.is_a?(Array) ? deep_to_a(v) : v
    end
  end
end
