# frozen_string_literal: true

require "spec_helper"

describe "InstallmentClassMethods"  do
  before do
    @creator = create(:named_user, :with_avatar)
    @installment = create(:installment, call_to_action_text: "CTA", call_to_action_url: "https://www.example.com", seller: @creator)
  end

  describe ".product_or_variant_with_sent_emails_for_purchases" do
    it "returns live product or variant installments that have been emailed to those purchasers" do
      product = create(:product)
      variant = create(:variant, variant_category: create(:variant_category, link: product))
      product_post = create(:installment, link: product, published_at: 1.day.ago)
      variant_post = create(:variant_installment, link: product, base_variant: variant, published_at: 1.day.ago)
      create(:seller_installment, seller: product.user)
      create(:installment, link: product, published_at: 1.day.ago, deleted_at: 1.day.ago)
      create(:variant_installment, link: product, base_variant: variant, published_at: nil)

      purchase = create(:purchase, link: product, variant_attributes: [variant])

      expect(Installment.product_or_variant_with_sent_emails_for_purchases([purchase.id])).to be_empty

      create(:creator_contacting_customers_email_info, installment: product_post, purchase:)
      expect(Installment.product_or_variant_with_sent_emails_for_purchases([purchase.id])).to match_array [product_post]

      create(:creator_contacting_customers_email_info, installment: variant_post, purchase:)
      expect(Installment.product_or_variant_with_sent_emails_for_purchases([purchase.id])).to match_array [product_post, variant_post]

      expect(Installment.product_or_variant_with_sent_emails_for_purchases([create(:purchase).id])).to be_empty
    end
  end

  describe ".seller_with_sent_emails_for_purchases" do
    it "returns live seller installments that have been emailed to those purchasers" do
      product = create(:product)
      purchase = create(:purchase, link: product)
      seller_post = create(:seller_installment, seller: product.user, published_at: 1.day.ago)
      create(:seller_installment, seller: product.user, published_at: 1.day.ago, deleted_at: 1.day.ago)
      create(:seller_installment, seller: product.user, published_at: nil)
      create(:installment, link: product, published_at: 1.day.ago)

      expect(Installment.seller_with_sent_emails_for_purchases([purchase.id])).to be_empty

      create(:creator_contacting_customers_email_info, installment: seller_post, purchase:)
      expect(Installment.seller_with_sent_emails_for_purchases([purchase.id])).to match_array [seller_post]
    end
  end

  describe ".profile_only_for_products" do
    it "returns live profile-only product posts for the given product IDs" do
      product1 = create(:product)
      product2 = create(:product)
      product1_post = create(:installment, link: product1, published_at: 1.day.ago, send_emails: false, shown_on_profile: true)
      product2_post = create(:installment, link: product2, published_at: 1.day.ago, send_emails: false, shown_on_profile: true)
      create(:installment, link: product1, send_emails: false, shown_on_profile: true)
      create(:installment, link: product2, published_at: nil, send_emails: false, shown_on_profile: true)
      create(:installment, link: product2, published_at: 1.day.ago, deleted_at: 1.day.ago, send_emails: false, shown_on_profile: true)
      create(:installment, link: product1, published_at: 1.day.ago, shown_on_profile: true)
      create(:installment, link: product2, published_at: 1.day.ago)
      create(:installment, published_at: 1.day.ago, send_emails: false, shown_on_profile: true)

      expect(Installment.profile_only_for_products([product1.id, product2.id])).to match_array [product1_post, product2_post]
    end
  end

  describe ".profile_only_for_variant_ids" do
    it "returns live profile-only variant posts for the given variant IDs" do
      product = create(:product)
      variant1 = create(:variant, variant_category: create(:variant_category, link: product))
      variant2 = create(:variant, variant_category: create(:variant_category, link: product))
      variant1_post = create(:variant_installment, link: product, base_variant: variant1, published_at: 1.day.ago, send_emails: false, shown_on_profile: true)
      variant2_post = create(:variant_installment, link: product, base_variant: variant2, published_at: 1.day.ago, send_emails: false, shown_on_profile: true)
      create(:variant_installment, link: product, base_variant: variant1, published_at: nil, send_emails: false, shown_on_profile: true)
      create(:variant_installment, link: product, base_variant: variant1, published_at: 1.day.ago, deleted_at: 1.day.ago, send_emails: false, shown_on_profile: true)
      create(:variant_installment, link: product, base_variant: variant2, published_at: 1.day.ago, shown_on_profile: true)
      create(:variant_installment, link: product, base_variant: variant2, published_at: 1.day.ago)
      create(:installment, link: product, published_at: 1.day.ago, send_emails: false, shown_on_profile: true)

      expect(Installment.profile_only_for_variants([variant1.id, variant2.id])).to match_array [variant1_post, variant2_post]
    end
  end

  describe ".profile_only_for_sellers" do
    it "returns live profile-only seller posts for the given seller IDs" do
      seller1 = create(:user)
      seller2 = create(:user)
      seller1_post = create(:seller_installment, seller: seller1, published_at: 1.day.ago, send_emails: false, shown_on_profile: true)
      seller2_post = create(:seller_installment, seller: seller2, published_at: 1.day.ago, send_emails: false, shown_on_profile: true)
      create(:seller_installment, seller: seller1, published_at: nil, send_emails: false, shown_on_profile: true)
      create(:seller_installment, seller: seller2, published_at: 1.day.ago, deleted_at: 1.day.ago, send_emails: false, shown_on_profile: true)
      create(:seller_installment, seller: seller1, published_at: 1.day.ago, shown_on_profile: true)
      create(:seller_installment, seller: seller2, published_at: 1.day.ago)
      create(:seller_installment, published_at: 1.day.ago, send_emails: false, shown_on_profile: true)
      create(:installment, seller: seller1, published_at: 1.day.ago)

      expect(Installment.profile_only_for_sellers([seller1.id, seller2.id])).to match_array [seller1_post, seller2_post]
    end
  end

  describe ".for_products" do
    it "returns live, non-workflow product-posts for the given products" do
      product1 = create(:product)
      product2 = create(:product)
      product_ids = [product1.id, product2.id]
      posts = [
        create(:product_installment, :published, link: product1),
        create(:product_installment, :published, link: product2),
      ]
      create(:product_installment, link: product1)
      create(:product_installment, :published, link: product2, deleted_at: 1.day.ago)
      create(:product_installment, :published)
      create(:seller_installment, :published, seller: product1.user)
      create(:workflow_installment, :published, link: product1)

      expect(Installment.for_products(product_ids:)).to match_array posts
    end
  end

  describe ".for_variants" do
    it "returns live, non-workflow variant-posts for the given variants" do
      variant1 = create(:variant)
      variant2 = create(:variant)
      variant_ids = [variant1.id, variant2.id]
      posts = [
        create(:variant_installment, :published, base_variant: variant1),
        create(:variant_installment, :published, base_variant: variant2),
      ]
      create(:variant_installment, base_variant: variant1)
      create(:variant_installment, :published, base_variant: variant2, deleted_at: 1.day.ago)
      create(:variant_installment, :published)
      create(:seller_installment, :published, seller: variant1.user)
      create(:workflow_installment, :published, base_variant: variant1)

      expect(Installment.for_variants(variant_ids:)).to match_array posts
    end
  end

  describe ".for_sellers" do
    it "returns live, non-workflow seller-posts for the given sellers" do
      seller1 = create(:user)
      seller2 = create(:user)
      seller_ids = [seller1.id, seller2.id]
      posts = [
        create(:seller_installment, :published, seller: seller1),
        create(:seller_installment, :published, seller: seller2),
      ]
      create(:seller_installment, seller: seller1)
      create(:seller_installment, :published, seller: seller2, deleted_at: 1.day.ago)
      create(:seller_installment, :published)
      create(:product_installment, :published, seller: seller1)
      create(:variant_installment, :published, seller: seller1)
      create(:workflow_installment, :published, seller: seller1)

      expect(Installment.for_sellers(seller_ids:)).to match_array posts
    end
  end

  describe ".past_posts_to_show_for_products" do
    before do
      @enabled_product = create(:product, should_show_all_posts: true)
      @disabled_product = create(:product, should_show_all_posts: false)
      @enabled_product_post1 = create(:installment, link: @enabled_product, published_at: 1.day.ago)
      @enabled_product_post2 = create(:installment, link: @enabled_product, published_at: 1.day.ago)
      create(:installment, link: @enabled_product, published_at: nil)
      create(:installment, link: @disabled_product, published_at: 1.day.ago)
      workflow = create(:workflow, link: @enabled_product, workflow_type: Workflow::PRODUCT_TYPE)
      create(:installment, workflow:, link: @enabled_product, published_at: 1.day.ago)
    end

    it "returns live product posts for products with should_show_all_posts enabled" do
      expect(Installment.past_posts_to_show_for_products(product_ids: [@enabled_product.id, @disabled_product.id])).to match_array [@enabled_product_post1, @enabled_product_post2]
    end

    it "excludes certain post IDs, if provided" do
      expect(Installment.past_posts_to_show_for_products(product_ids: [@enabled_product.id, @disabled_product.id], excluded_post_ids: [@enabled_product_post1.id])).to match_array [@enabled_product_post2]
    end
  end

  describe ".past_posts_to_show_for_variants" do
    before do
      enabled_product = create(:product, should_show_all_posts: true)
      @enabled_variant = create(:variant, variant_category: create(:variant_category, link: enabled_product))
      @disabled_variant = create(:variant)
      @enabled_variant_post1 = create(:variant_installment, link: enabled_product, base_variant: @enabled_variant, published_at: 1.day.ago)
      @enabled_variant_post2 = create(:variant_installment, link: enabled_product, base_variant: @enabled_variant, published_at: 1.day.ago)
      create(:variant_installment, link: enabled_product, base_variant: @enabled_variant, published_at: nil)
      create(:variant_installment, link: @disabled_variant.link, base_variant: @disabled_variant, published_at: 1.day.ago)
    end

    it "returns live variant posts for variants whose products have should_show_all_posts enabled" do
      expect(Installment.past_posts_to_show_for_variants(variant_ids: [@enabled_variant.id, @disabled_variant.id])).to match_array [@enabled_variant_post1, @enabled_variant_post2]
    end

    it "excludes certain post IDs, if provided" do
      expect(Installment.past_posts_to_show_for_variants(variant_ids: [@enabled_variant.id, @disabled_variant.id], excluded_post_ids: [@enabled_variant_post1.id])).to match_array [@enabled_variant_post2]
    end
  end

  describe ".seller_posts_for_sellers" do
    before do
      @seller = create(:user)
      @seller_post1 = create(:seller_installment, seller: @seller, published_at: 1.day.ago)
      @seller_post2 = create(:seller_installment, seller: @seller, published_at: 1.day.ago)
      create(:seller_installment, seller: @seller, published_at: nil)
      create(:seller_installment, published_at: 1.day.ago)
    end

    it "returns live seller posts for the given seller IDs" do
      expect(Installment.seller_posts_for_sellers(seller_ids: [@seller.id])).to match_array [@seller_post1, @seller_post2]
    end

    it "excludes certain post IDs, if provided" do
      expect(Installment.seller_posts_for_sellers(seller_ids: [@seller.id], excluded_post_ids: [@seller_post1.id])).to match_array [@seller_post2]
    end
  end

  describe ".emailable_posts_for_purchase" do
    it "returns the product-, variant-, and seller-type posts for the purchase where send_emails is true" do
      product = create(:product)
      variant = create(:variant, variant_category: create(:variant_category, link: product))
      purchase = create(:purchase, link: product, variant_attributes: [variant])
      posts = [
        create(:product_installment, :published, link: product),
        create(:product_installment, :published, link: product),
        create(:variant_installment, :published, base_variant: variant),
        create(:seller_installment, :published, seller: product.user),
      ]
      create(:product_installment, :published, link: product, send_emails: false, shown_on_profile: true)
      create(:product_installment, link: product)
      create(:variant_installment, :published, base_variant: variant, deleted_at: 1.day.ago)
      create(:workflow_installment, link: product, seller: product.user)

      expect(Installment.emailable_posts_for_purchase(purchase:)).to match_array posts
    end
  end

  describe ".filter_by_product_id_if_present" do
    before do
      @creator = create(:named_user)
      @product = create(:product, name: "product name", user: @creator)
      @product_post = create(:installment, link: @product, name: "product update", message: "content for update post 1", published_at: Time.current, shown_on_profile: true, seller: @creator)
      @audience_post = create(:audience_installment, name: "audience update", message: "content for update post 1", seller: @creator, published_at: Time.current, shown_on_profile: true)

      another_product = create(:product, name: "product name", user: @creator)
      @another_product_post = create(:installment, link: another_product, name: "product update", message: "content for update post 1", published_at: Time.current, shown_on_profile: true, seller: @creator)
    end

    it "returns the proper product updates if filtered by product ID" do
      product_filtered_posts = Installment.filter_by_product_id_if_present(@product.id)

      expect(product_filtered_posts.length).to eq 1
      expect(product_filtered_posts).to include(@product_post)
      expect(product_filtered_posts).to_not include(@audience_post)
      expect(product_filtered_posts).to_not include(@another_product_post)
    end

    it "does not apply any scope if no product_id present" do
      product_filtered_posts = Installment.filter_by_product_id_if_present(nil)

      expect(product_filtered_posts.length).to eq 4
    end
  end

  describe ".missed_for_purchase" do
    before do
      @creator = create(:user)
      @product = create(:product, user: @creator)
      @purchase = create(:purchase, link: @product)
    end

    it "returns only the posts sent by seller in case there are posts belonging to other user" do
      sent_installment = create(:installment, link: @product, seller: @creator, published_at: Time.current)
      create(:creator_contacting_customers_email_info, installment: sent_installment, purchase: @purchase)
      sellers_post = create(:installment, link: @product, published_at: Time.current)
      create(:installment, link: @product, seller: create(:user), published_at: Time.current)

      product_filtered_posts = Installment.missed_for_purchase(@purchase)

      expect(product_filtered_posts).to eq [sellers_post]
    end

    it "includes posts sent to customers of multiple products if it includes the bought product" do
      post_to_multiple_products = create(:seller_installment, seller: @creator,
                                                              bought_products: [@product.unique_permalink, create(:product, user: @creator).unique_permalink],
                                                              published_at: 2.days.ago)

      already_received_post = create(:seller_installment, seller: @creator,
                                                          bought_products: [@product.unique_permalink, create(:product, user: @creator).unique_permalink],
                                                          published_at: 1.day.ago)
      create(:creator_contacting_customers_email_info, installment: already_received_post, purchase: @purchase)

      missed_posts = Installment.missed_for_purchase(@purchase)

      expect(missed_posts).to eq [post_to_multiple_products]
    end

    it "includes posts sent to all customers" do
      seller_post = create(:seller_installment, seller: @creator, published_at: 2.days.ago)

      missed_posts = Installment.missed_for_purchase(@purchase)

      expect(missed_posts).to eq [seller_post]
    end

    it "includes posts sent to audience" do
      seller_post = create(:audience_installment, seller: @creator, published_at: 2.days.ago)

      missed_posts = Installment.missed_for_purchase(@purchase)

      expect(missed_posts).to eq [seller_post]
    end

    it "does not include post sent to customers of multiple products if it is already sent to the purchase email" do
      product_1 = create(:product, user: @creator)
      product_2 = create(:product, user: @creator)
      purchase_1 = create(:purchase, link: product_1, email: "bot@gum.co")
      purchase_2 = create(:purchase, link: product_2, email: "bot@gum.co")
      post = create(:seller_installment, seller: @creator, published_at: 2.days.ago,
                                         bought_products: [product_1.unique_permalink, product_2.unique_permalink])
      create(:creator_contacting_customers_email_info, installment: post, purchase: purchase_1)

      missed_posts = Installment.missed_for_purchase(purchase_2)

      expect(missed_posts).to eq []
    end

    it "does not include profile-only posts" do
      product_post = create(:installment, link: @product, seller: @creator, published_at: 3.days.ago)
      product_post.send_emails = false
      product_post.shown_on_profile = true
      product_post.save!

      seller_post = create(:seller_installment, seller: @creator,
                                                bought_products: [@product.unique_permalink, create(:product, user: @creator).unique_permalink],
                                                published_at: 2.days.ago)
      seller_post.send_emails = false
      seller_post.shown_on_profile = true
      seller_post.save!

      missed_posts = Installment.missed_for_purchase(@purchase)

      expect(missed_posts).to eq []
    end

    it "does not include workflow installments for different variants" do
      variant_basic = create(:variant, variant_category: create(:variant_category, link: @product))
      variant_power = create(:variant, variant_category: create(:variant_category, link: @product))

      workflow_for_basic = create(:workflow, link: @product, seller: @creator, base_variant: variant_basic, workflow_type: Workflow::VARIANT_TYPE, bought_variants: [variant_basic.external_id])
      workflow_installment = create(:workflow_installment, workflow: workflow_for_basic, link: @product, seller: @creator, published_at: 1.day.ago)

      purchase_with_power_variant = create(:purchase, link: @product, seller: @creator, variant_attributes: [variant_power])

      missed_posts = Installment.missed_for_purchase(purchase_with_power_variant)

      expect(missed_posts).not_to include(workflow_installment)
    end

    it "includes workflow installments for matching variants" do
      variant_basic = create(:variant, variant_category: create(:variant_category, link: @product))

      workflow_for_basic = create(:workflow, link: @product, seller: @creator, base_variant: variant_basic, workflow_type: Workflow::VARIANT_TYPE, bought_variants: [variant_basic.external_id])
      workflow_installment = create(:workflow_installment, workflow: workflow_for_basic, link: @product, seller: @creator, published_at: 1.day.ago)

      purchase_with_basic_variant = create(:purchase, link: @product, seller: @creator, variant_attributes: [variant_basic])

      missed_posts = Installment.missed_for_purchase(purchase_with_basic_variant)

      expect(missed_posts).to include(workflow_installment)
    end
  end
end
