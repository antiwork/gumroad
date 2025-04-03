# frozen_string_literal: true

require "spec_helper"

describe User::Posts, :freeze_time do
  describe "visible_posts_for", :vcr do
    before do
      @creator = create(:named_user)
      product = create(:product, name: "product name", user: @creator)
      product_2 = create(:product, name: "product 2 name", user: @creator)
      product_3 = create(:product, name: "product 3 name", user: @creator)
      @membership = create(:membership_product, user: @creator)
      @dude = create(:user, username: "dude")
      create(:purchase, link: product, seller: @creator, purchaser: @dude, created_at: 1.hour.ago, price_cents: 100)
      create(:purchase, link: product, seller: @creator, purchaser: @dude, created_at: Time.current, price_cents: 500)
      create(:purchase, link: product_2, seller: @creator, purchaser: @dude, created_at: 1.hour.ago, price_cents: 1000)
      purchase = create(:membership_purchase, link: @membership, seller: @creator, purchaser: @dude, price_cents: 500, created_at: 1.day.ago)
      purchase.subscription.update!(cancelled_at: 1.hour.ago, deactivated_at: 1.hour.ago)

      @dude_chargedback = create(:user, username: "chargedbackdude")
      create(:disputed_purchase, link: product, seller: @creator, purchaser: @dude_chargedback, created_at: 1.hour.ago, price_cents: 200)
      create(:purchase, link: product_2, seller: @creator, purchaser: @dude_chargedback, price_cents: 300)

      @follower = create(:user, email: "follower@gum.co")
      create(:follower, user: @creator, email: @follower.email, confirmed_at: Time.current)
      workflow = create(:workflow, link: product, seller: @creator)
      @direct_affiliate = create(:direct_affiliate, seller: @creator)
      create(:product_affiliate, product:, affiliate: @direct_affiliate)

      @audience_post = create(:audience_installment, name: "audience post shown", seller: @creator, published_at: Time.current, shown_on_profile: true)
      create(:audience_installment, name: "hide me because not published", seller: @creator, shown_on_profile: true)
      @audience_post_not_on_profile = create(:audience_installment, name: "hide me because shown_on_profile=false", seller: @creator, published_at: Time.current, shown_on_profile: false)
      create(:audience_installment, name: "hide me because workflow update", workflow_id: workflow.id, seller: @creator, published_at: Time.current, shown_on_profile: true)
      create(:audience_installment, name: "audience post from different seller", seller: create(:user), published_at: Time.current, shown_on_profile: true)

      @seller_post = create(:seller_installment, name: "seller post shown", seller: @creator, published_at: 2.hours.ago, shown_on_profile: true)
      @seller_post_with_filters = create(:seller_installment, name: "seller post with filters", seller: @creator, published_at: 2.hours.ago, shown_on_profile: true, json_data: { created_after: 1.month.ago, paid_more_than_cents: 100, paid_less_than_cents: 1000, bought_products: [product_2.unique_permalink], not_bought: [product_3.unique_permalink] })
      create(:seller_installment, name: "hide seller post because unmet filters", seller: @creator, published_at: 2.hours.ago, shown_on_profile: true, json_data: { paid_more_than_cents: 1100, paid_less_than_cents: 2000 })
      create(:seller_installment, name: "hide seller post 2 because unmet filters", seller: @creator, published_at: 2.hours.ago, shown_on_profile: true, json_data: { created_after: 1.month.ago, created_before: 1.week.ago })
      create(:seller_installment, name: "hide seller post 3 because unmet filters", seller: @creator, published_at: 2.hours.ago, shown_on_profile: true, json_data: { created_after: 1.month.ago, paid_more_than_cents: 1500 })
      create(:seller_installment, name: "hide seller post 4 because unmet filters", seller: @creator, published_at: 2.hours.ago, shown_on_profile: true, json_data: { created_before: 1.month.ago, paid_more_than_cents: 100, paid_less_than_cents: 1000 })
      create(:seller_installment, name: "hide seller post 5 because unmet filters", seller: @creator, published_at: 2.hours.ago, shown_on_profile: true, json_data: { created_before: 1.month.ago, paid_more_than_cents: 100, paid_less_than_cents: 1000, bought_products: [product_2.unique_permalink], not_bought: [product_3.unique_permalink] })
      create(:seller_installment, seller: @creator, name: "hide me because not published", shown_on_profile: true)
      @seller_post_not_on_profile = create(:installment, installment_type: "seller", seller: @creator, name: "hide me because shown_on_profile=false", published_at: Time.current, shown_on_profile: false)
      create(:seller_installment, seller: @creator, name: "hide me because workflow update", workflow_id: workflow.id, published_at: Time.current, shown_on_profile: true)
      create(:seller_installment, seller: create(:user), name: "seller post from different seller", published_at: Time.current, shown_on_profile: true)

      @product_post = create(:installment, link: product, name: "product post shown", published_at: Time.current, shown_on_profile: true)
      create(:installment, link: product, name: "hide be because not published", shown_on_profile: true)
      create(:installment, link: product, name: "hide me because published before purchase", published_at: 2.hours.ago, shown_on_profile: true)
      @product_post_not_on_profile = create(:installment, link: product, name: "hide me because shown_on_profile=false", published_at: Time.current, shown_on_profile: false)
      create(:installment, link: product, name: "hide me because workflow update", workflow_id: workflow.id, published_at: Time.current, shown_on_profile: true)
      @product_post_2 = create(:installment, link: product_2, name: "product post 2 shown", published_at: Time.current, shown_on_profile: true)
      create(:installment, link: create(:product), name: "product post from different seller's product", published_at: Time.current, shown_on_profile: true)

      @membership_post = create(:installment, link: @membership, name: "membership post shown", published_at: 2.hours.ago, shown_on_profile: true)
      create(:installment, link: @membership, name: "membership hidden because published after cancellation", published_at: 50.minutes.ago, shown_on_profile: true)
      @membership_post_not_on_profile = create(:installment, link: @membership, name: "membership post hidden because shown_on_profile=false", published_at: 2.hours.ago, shown_on_profile: false)
      create(:installment, link: @membership, name: "membership hidden because published after cancellation", published_at: 50.minutes.ago, shown_on_profile: false)

      @follower_post = create(:follower_installment, seller: @creator, name: "follower post shown", published_at: 1.hour.ago, shown_on_profile: true)
      @follower_post_with_filters = create(:follower_installment, seller: @creator, name: "follower post with filters shown", published_at: 1.hour.ago, shown_on_profile: true, json_data: { created_after: 1.week.ago })
      create(:follower_installment, seller: @creator, name: "hide follower post with unmet filters", published_at: 1.hour.ago, shown_on_profile: true, json_data: { created_after: 1.week.ago, created_before: 1.day.ago })
      create(:follower_installment, seller: @creator, name: "hide follower post 2 with unmet filters", published_at: 1.hour.ago, shown_on_profile: true, json_data: { created_before: 1.day.ago })
      create(:follower_installment, seller: @creator, name: "hide be because not published", shown_on_profile: true)
      @follower_post_not_on_profile = create(:follower_installment, seller: @creator, name: "hide be because shown_on_profile=false", published_at: Time.current, shown_on_profile: false)
      create(:follower_installment, seller: @creator, name: "hide me because workflow update", workflow_id: workflow.id, published_at: Time.current, shown_on_profile: true)
      create(:follower_installment, seller: create(:user), name: "follower post from different seller", published_at: Time.current, shown_on_profile: true)

      @affiliate_post = create(:affiliate_installment, seller: @creator, name: "affiliate post", published_at: Time.current, json_data: { affiliate_products: [product.unique_permalink, product_2.unique_permalink], created_after: 1.week.ago })
      create(:affiliate_installment, seller: @creator, name: "hide me affiliate post because unmet filters", published_at: Time.current, json_data: { affiliate_products: [product_2.unique_permalink] })
      create(:affiliate_installment, seller: @creator, name: "hide me affiliate post 2 because unmet filters", published_at: Time.current, json_data: { created_before: 1.day.ago })
      create(:affiliate_installment, seller: @creator, name: "hide me because not published")
      create(:affiliate_installment, seller: @creator, name: "hide me because workflow update", workflow_id: workflow.id, published_at: Time.current)
    end

    describe "posts with shown_on_profile true" do
      it "returns only audience posts that are shown on profile if logged_in_user is not present or is not a customer or follower" do
        pundit_user = SellerContext.logged_out
        visible_posts = @creator.visible_posts_for(pundit_user:)
        expect(visible_posts).to contain_exactly(@audience_post)

        user = create(:user)
        pundit_user = SellerContext.new(user:, seller: user)
        visible_posts = @creator.visible_posts_for(pundit_user:)
        expect(visible_posts).to contain_exactly(@audience_post)
      end

      it "returns audience posts and posts from purchased products that are shown on profile when logged_in_user is a customer" do
        pundit_user = SellerContext.new(user: @dude, seller: @dude)
        visible_posts = @creator.visible_posts_for(pundit_user:)
        expect(visible_posts).to contain_exactly(@audience_post,
                                                 @seller_post,
                                                 @seller_post_with_filters,
                                                 @product_post,
                                                 @product_post_2,
                                                 @membership_post)
      end

      it "returns audience posts and follower posts that are shown on profile when logged_in_user is a follower" do
        pundit_user = SellerContext.new(user: @follower, seller: @follower)
        visible_posts = @creator.visible_posts_for(pundit_user:)
        expect(visible_posts).to contain_exactly(@audience_post,
                                                 @follower_post,
                                                 @follower_post_with_filters)
      end

      it "returns only audience posts that are shown on profile when logged_in_user is an affiliate" do
        affiliate_user = @direct_affiliate.affiliate_user
        pundit_user = SellerContext.new(user: affiliate_user, seller: affiliate_user)
        visible_posts = @creator.visible_posts_for(pundit_user:)

        expect(visible_posts.length).to eq 1
        expect(visible_posts).to contain_exactly(@audience_post)
      end

      it "returns audience posts, seller posts, follower posts, and product/variant posts that are shown on profile from purchased products when logged_in_user is a follower and a customer" do
        create(:follower, user: @creator, email: @dude.email, confirmed_at: Time.current)

        pundit_user = SellerContext.new(user: @dude, seller: @dude)
        visible_posts = @creator.visible_posts_for(pundit_user:)
        expect(visible_posts).to contain_exactly(@audience_post,
                                                 @seller_post,
                                                 @seller_post_with_filters,
                                                 @product_post,
                                                 @product_post_2,
                                                 @follower_post,
                                                 @follower_post_with_filters,
                                                 @membership_post)
      end

      it "returns audience posts, seller posts, follower posts, and product/variant posts that are shown on profile from valid purchases when logged_in_user is a customer" do
        pundit_user = SellerContext.new(user: @dude_chargedback, seller: @dude_chargedback)
        visible_posts = @creator.visible_posts_for(pundit_user:)
        expect(visible_posts).to contain_exactly(@audience_post,
                                                 @seller_post,
                                                 @seller_post_with_filters,
                                                 @product_post_2)
      end
    end

    describe "all posts irrespective of shown_on_profile" do
      it "returns only audience posts that are shown on profile if logged_in_user is not present or is not a customer or follower" do
        pundit_user = SellerContext.logged_out
        visible_posts = @creator.visible_posts_for(pundit_user:, shown_on_profile: false)
        expect(visible_posts).to contain_exactly(@audience_post)

        user = create(:user)
        pundit_user = SellerContext.new(user:, seller: user)
        visible_posts = @creator.visible_posts_for(pundit_user:, shown_on_profile: false)
        expect(visible_posts).to contain_exactly(@audience_post)
      end

      it "returns all audience posts and posts from purchased products when logged_in_user is a customer" do
        pundit_user = SellerContext.new(user: @dude, seller: @dude)
        visible_posts = @creator.visible_posts_for(pundit_user:, shown_on_profile: false)
        expect(visible_posts).to contain_exactly(@audience_post,
                                                 @audience_post_not_on_profile,
                                                 @seller_post,
                                                 @seller_post_with_filters,
                                                 @seller_post_not_on_profile,
                                                 @product_post,
                                                 @product_post_not_on_profile,
                                                 @product_post_2,
                                                 @membership_post,
                                                 @membership_post_not_on_profile)
      end

      it "returns audience posts and follower posts when logged_in_user is a follower" do
        pundit_user = SellerContext.new(user: @follower, seller: @follower)
        visible_posts = @creator.visible_posts_for(pundit_user:, shown_on_profile: false)
        expect(visible_posts).to contain_exactly(@audience_post,
                                                 @audience_post_not_on_profile,
                                                 @follower_post,
                                                 @follower_post_with_filters,
                                                 @follower_post_not_on_profile)
      end

      it "returns audience posts and affiliate posts when logged_in_user is an affiliate" do
        affiliate_user = @direct_affiliate.affiliate_user
        pundit_user = SellerContext.new(user: affiliate_user, seller: affiliate_user)
        visible_posts = @creator.visible_posts_for(pundit_user:, shown_on_profile: false)
        expect(visible_posts).to contain_exactly(@audience_post,
                                                 @audience_post_not_on_profile,
                                                 @affiliate_post)
      end

      it "returns audience posts, seller posts, follower posts, and product/variant posts from purchased products when logged_in_user is a follower and a customer" do
        create(:follower, user: @creator, email: @dude.email, confirmed_at: Time.current)
        pundit_user = SellerContext.new(user: @dude, seller: @dude)
        visible_posts = @creator.visible_posts_for(pundit_user:, shown_on_profile: false)
        expect(visible_posts).to contain_exactly(@audience_post,
                                                 @audience_post_not_on_profile,
                                                 @seller_post,
                                                 @seller_post_with_filters,
                                                 @seller_post_not_on_profile,
                                                 @product_post,
                                                 @product_post_not_on_profile,
                                                 @product_post_2,
                                                 @follower_post,
                                                 @follower_post_with_filters,
                                                 @follower_post_not_on_profile,
                                                 @membership_post,
                                                 @membership_post_not_on_profile)
      end
    end

    context "user has stopped and restarted subscription" do
      it "does not return posts published while the subscription was stopped" do
        membership_buyer = create(:user, username: "membershipbuyer")
        membership_purchase = create(:membership_purchase, link: @membership, seller: @creator, purchaser: membership_buyer, price_cents: 500, created_at: 7.months.ago)
        subscription = membership_purchase.subscription

        membership_post_1 = create(:installment, link: @membership, name: "membership post 1", published_at: 6.months.ago, shown_on_profile: true)
        create(:subscription_event, subscription:, event_type: :deactivated, occurred_at: 5.months.ago)
        membership_post_2 = create(:installment, link: @membership, name: "membership post 2", published_at: 4.months.ago, shown_on_profile: true)
        create(:subscription_event, subscription:, event_type: :restarted, occurred_at: 3.months.ago)
        membership_post_3 = create(:installment, link: @membership, name: "membership post 3", published_at: 2.months.ago, shown_on_profile: true)
        create(:subscription_event, subscription:, event_type: :deactivated, occurred_at: 1.month.ago)
        membership_post_4 = create(:installment, link: @membership, name: "membership post 4", published_at: 2.weeks.ago, shown_on_profile: true)

        pundit_user = SellerContext.new(user: membership_buyer, seller: membership_buyer)
        visible_posts = @creator.visible_posts_for(pundit_user:, shown_on_profile: false)
        expect(visible_posts).to include(membership_post_1, membership_post_3)
        expect(visible_posts).not_to include(membership_post_2, membership_post_4)
      end
    end
  end

  describe "#last_5_created_posts" do
    let(:seller) { create(:named_user) }
    let(:product) { create(:product, user: seller) }

    let!(:post_1) { create(:installment, link: product, published_at: 1.minute.ago, created_at: 3.hours.ago) }
    let!(:post_2) { create(:installment, link: product, published_at: nil, created_at: 2.hours.ago) }
    let!(:post_3) { create(:installment, link: product, deleted_at: 1.hour.ago, created_at: 1.hour.ago) }

    it "includes deleted and not published posts" do
      posts = seller.last_5_created_posts
      expect(posts).to eq([post_3, post_2, post_1])
    end
  end
end
