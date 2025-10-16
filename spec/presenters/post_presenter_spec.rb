# frozen_string_literal: true

require "spec_helper"

describe PostPresenter do
  before do
    @creator = create(:named_user)
    @product = create(:product, user: @creator)
    @product_post = create(:published_installment, link: @product, seller: @creator, call_to_action_url: "https://example.com", call_to_action_text: "Example")
    @follower_post = create(:follower_installment, seller: @creator, published_at: 3.days.ago, shown_on_profile: true)
    @user = create(:user)
    @purchase = create(:purchase, link: @product, purchaser: @user, created_at: 1.minute.ago)
    create(:follower, user: @creator, email: @user.email, confirmed_at: Time.current)
  end

  describe "#initialize" do
    it "sets the presented identifiers as instance variables" do
      pundit_user = SellerContext.new(user: @user, seller: @user)
      presenter_with_logged_in_user = PostPresenter.new(pundit_user:, post: @product_post, purchase_id_param: nil)

      expect(presenter_with_logged_in_user.post).to eq @product_post
      expect(presenter_with_logged_in_user.pundit_user).to eq pundit_user
      expect(presenter_with_logged_in_user.purchase).to eq @purchase

      another_product = create(:product, user: @creator)
      another_purchase = create(:purchase, link: another_product, purchaser: @user)
      pundit_user = SellerContext.logged_out
      user_presenter = PostPresenter.new(pundit_user:, post: @product_post, purchase_id_param: another_purchase.external_id)
      expect(user_presenter.post).to eq @product_post
      expect(user_presenter.purchase).to eq another_purchase
    end
  end

  describe "#post_component_props" do
    before do
      @comment1 = create(:comment, commentable: @product_post, author: @user, created_at: 20.seconds.ago)
      @comment1_reply = create(:comment, commentable: @product_post, author: @user, parent: @comment1, created_at: 10.seconds.ago)
      @comment2 = create(:comment, commentable: @product_post, created_at: Time.current)
      @another_product_post = create(:published_installment, link: @product, seller: @creator)
      create(:seller_profile_posts_section, seller: @creator, shown_posts: [])
    end

    it "returns props for the post component" do
      @creator.reload
      pundit_user = SellerContext.new(user: @user, seller: @user)
      presenter = PostPresenter.new(pundit_user:, post: @product_post, purchase_id_param: "test")

      expect(presenter.post_component_props).to eq(
        creator_profile: ProfilePresenter.new(pundit_user:, seller: @creator).creator_profile,
        subject: @product_post.subject,
        slug: @product_post.slug,
        external_id: @product_post.external_id,
        purchase_id: nil,
        published_at: @product_post.published_at,
        message: @product_post.message,
        call_to_action: { text: "Example", url: "https://example.com" },
        download_url: nil,
        has_posts_on_profile: true,
        recent_posts: [{
          name: @another_product_post.name,
          published_at: @another_product_post.published_at,
          slug: @another_product_post.slug,
          truncated_description: @another_product_post.truncated_description,
          purchase_id: @purchase.external_id
        }],
        paginated_comments: {
          comments: [
            {
              id: @comment1.external_id,
              parent_id: nil,
              author_id: @comment1.author.external_id,
              author_name: @comment1.author.display_name,
              author_avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
              purchase_id: nil,
              content: { original: @comment1.content, formatted: CGI.escapeHTML(@comment1.content) },
              created_at: @comment1.created_at.iso8601,
              created_at_humanized: "less than a minute ago",
              depth: 0,
              is_editable: true,
              is_deletable: true
            },
            {
              id: @comment1_reply.external_id,
              parent_id: @comment1.external_id,
              author_id: @comment1_reply.author.external_id,
              author_name: @comment1_reply.author.display_name,
              author_avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
              purchase_id: nil,
              content: { original: @comment1_reply.content, formatted: CGI.escapeHTML(@comment1_reply.content) },
              created_at: @comment1_reply.created_at.iso8601,
              created_at_humanized: "less than a minute ago",
              depth: 1,
              is_editable: true,
              is_deletable: true
            },
            {
              id: @comment2.external_id,
              parent_id: nil,
              author_id: @comment2.author.external_id,
              author_name: @comment2.author.display_name,
              author_avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
              purchase_id: nil,
              content: { original: @comment2.content, formatted: CGI.escapeHTML(@comment2.content) },
              created_at: @comment2.created_at.iso8601,
              created_at_humanized: "less than a minute ago",
              depth: 0,
              is_editable: false,
              is_deletable: false
            }
          ],
          count: 3,
          pagination: {
            count: 2,
            items: PaginatedCommentsPresenter::COMMENTS_PER_PAGE,
            last: 1,
            pages: 1,
            page: 1,
            next: nil,
            prev: nil
          }
        },
        comments_max_allowed_depth: 4,
      )
    end

    context "when 'allow_comments' flag is disabled" do
      pundit_user = SellerContext.logged_out
      let(:presenter) { PostPresenter.new(pundit_user:, post: create(:published_installment, allow_comments: false), purchase_id_param: "test") }

      it "responds with 'paginated_comments' set to nil" do
        expect(presenter.post_component_props[:paginated_comments]).to be_nil
      end
    end
  end

  describe ".snippet" do
    it "returns a sanitized version of the message limited to 150 characters" do
      message = Faker::Lorem.paragraphs(number: 10).join
      post = create(:published_installment, seller: @user, message:)
      pundit_user = SellerContext.new(user: @user, seller: @user)
      presenter = PostPresenter.new(pundit_user:, post:, purchase_id_param: nil)
      expect(presenter.snippet).to eq(message.first(150))
    end

    it "snips post the sanitization and retains more information" do
      message = "<div class=\"medium-insert-images contains-image-1530256361\"><figure contenteditable=\"false\">\n    <img src=\"#{AWS_S3_ENDPOINT}/gumroad/files/6282492303727/495e31a6aa1b41b5b580ed6775899d2e/original/TwitterGraphic.png\" alt=\"\">\n        \n</figure></div><p class=\"\">Today, we're launching the Gumroad creator dashboard app for Android.</p><p class=\"\">You can download it from the Play store here:&nbsp;<a href=\"https://play.google.com/store/apps/details?id=com.gumroad.creator\" target=\"_blank\" rel=\"noopener noreferrer\">https://play.google.com/store/apps/details?id=com.gumroad.creator</a></p><h3>Feature Parity</h3><p class=\"\">Once you log into your Gumroad account on the Android app, you'll be able to see daily, monthly, and lifetime sales on your account. For each transaction, you can see your customer's email, what they bought, when they bought it, and how much they paid. If you have email notifications turned on, you can also get push notifications from the app itself every time you make a sale. This matches the functionality of the iOS app.<br></p><div class=\"medium-insert-images contains-image--2098371296\"><figure contenteditable=\"false\">\n    <img src=\"#{AWS_S3_ENDPOINT}/gumroad/files/6282492303727/77b3ca4900024c91a9fd192307784177/original/screenshot_frame_light1-2.png\" alt=\"\">\n        \n</figure></div><p>The app is a read-only view of this data: you can't issue refunds, look at analytics, send posts, or take any other actions on the app. For that, you'll need to head over to your account on the web. The app also does not currently show sales that you drove as an affiliate. Now that we have an iOS and an Android engineer working at Gumroad again, we will be able to bring more feature updates to all Gumroad apps, though our upcoming focus is on improving the consumer app on both operating systems.</p><p>Oh, and we couldn't resist throwing in one thing that iOS doesn't have: dark mode!</p><div class=\"medium-insert-images contains-image--738016557\"><figure contenteditable=\"false\">\n    <img src=\"#{AWS_S3_ENDPOINT}/gumroad/files/6282492303727/7e96cabd43d74332bbfcc842fafe78d3/original/screenshot_frame_dark1.png\" alt=\"\">\n        \n</figure></div><h3>Why We Built It</h3><p class=\"\">Gumroad builds tools for creators, which includes building tools for said creators' audiences. With limited engineering resources, we focus on building for the web, which is cross-platform and gives the highest return on investment. However, we offer both creators and their audiences apps. The Gumroad app for customers is the Gumroad library app, which lets you download and view content that you've bought on Gumroad. The creator app, also known as the dashboard app, lets you see your sales. While the customer app has been available on both Android and iOS for quite some time, the creator app was iOS-only until today.<br></p><p class=\"\">We are working on <a href=\"https://www.notion.so/gumroad/Roadmap-ce2ad07c483046e7941227ad7810730d\" target=\"_blank\" rel=\"noopener noreferrer\">lots of stuff </a>at Gumroad, so why invest in creating an Android app for creators? Well, people were asking for it, and the data backs up these requests.<br></p><div class=\"medium-insert-images contains-image-661100503\"><figure contenteditable=\"false\">\n    <img src=\"#{AWS_S3_ENDPOINT}/gumroad/files/6282492303727/b3f0237666c44981a372d4858b167455/original/Screen%20Shot%202020-12-07%20at%2010.19.46%20AM.png\" alt=\"\">\n        \n</figure></div><p>In November, 13.88% of creators with a session that included visiting gumroad.com/dashboard/sales viewed it on a device running android, but 20.07% of the sessions were from that OS. While more iOS users overall viewed the page, including more new users, they were responsible for far fewer sessions per user, suggesting that the availability of the iOS app cuts down on the amount of times creators have to check their analytics when all they want to know is recent and total sales figures.<br></p><h3>Available Today</h3><p class=\"\">If you are a Gumroad Creator with an Android device, download it today from the Google Play Store!<br></p><p class=\"\"><a href=\"https://play.google.com/store/apps/details?id=com.gumroad.creator\" target=\"_blank\" rel=\"noopener noreferrer\">https://play.google.com/store/apps/details?id=com.gumroad.creator</a><br></p><h3>Plus: Upcoming Event</h3><p class=\"\">On Wednesday, December 9th, at 10 AM PST, Randall Kanna is hosting \"The 5 Things You Need To Fix If You Want to Skyrocket your Sales\" on Zoom. Join live and ask questions or check the event out afterwards on YouTube.</p><p class=\"\">Register here:&nbsp;<a href=\"https://us02web.zoom.us/webinar/register/6416073525016/WN_qUH_4J-6TpW2dqiDc-PRhg\" target=\"_blank\" rel=\"noopener noreferrer\">https://us02web.zoom.us/webinar/register/6416073525016/WN_qUH_4J-6TpW2dqiDc-PRhg</a></p>"
      post = create(:published_installment, seller: @user, message:)
      pundit_user = SellerContext.new(user: @user, seller: @user)
      presenter = PostPresenter.new(pundit_user:, post:, purchase_id_param: nil)
      expect(presenter.snippet).to eq("Today, we're launching the Gumroad creator dashboard app for Android. You can download it from the Play store here: https://play.google.com/store/apps")
    end
  end

  describe "#social_image" do
    it "returns a Post::SocialImage with properly set url and caption" do
      post = build(
        :published_installment,
        seller: @user,
        message: <<~HTML
          <figure>
            <img src="path/to/image.jpg">
            <p class="figcaption">Caption</p>
          </figure>
        HTML
      )
      pundit_user = SellerContext.new(user: @user, seller: @user)
      presenter = PostPresenter.new(pundit_user:, post:, purchase_id_param: nil)
      expect(presenter.social_image.url).to eq("path/to/image.jpg")
      expect(presenter.social_image.caption).to eq("Caption")
    end
  end

  describe "#e404?" do
    let(:unpublished_post) { create(:installment, seller: @creator, published_at: nil) }
    let(:hidden_post) { create(:published_installment, seller: @creator, link: @product, shown_on_profile: false) }
    let(:workflow_post) { create(:workflow_installment, seller: @creator, link: @product, bought_products: [@product.unique_permalink]) }
    let(:seller_post) { create(:seller_post, seller: @creator, bought_products: [@product.external_id], shown_on_profile: true, send_emails: false) }

    context "when the creator is viewing the post" do
      let(:pundit_user) { SellerContext.new(user: @creator, seller: @creator) }

      it "returns false for an unpublished post" do
        presenter = PostPresenter.new(pundit_user:, post: unpublished_post, purchase_id_param: nil)
        expect(presenter.e404?).to be(false)
      end

      it "returns false for a shown_on_profile=false post" do
        presenter = PostPresenter.new(pundit_user:, post: hidden_post, purchase_id_param: nil)
        expect(presenter.e404?).to be(false)
      end

      it "returns false for a product post" do
        presenter = PostPresenter.new(pundit_user:, post: @product_post, purchase_id_param: nil)
        expect(presenter.e404?).to be(false)
      end

      it "returns false for a workflow post" do
        presenter = PostPresenter.new(pundit_user:, post: workflow_post, purchase_id_param: nil)
        expect(presenter.e404?).to be(false)
      end
    end

    context "when a customer with a relevant purchase is viewing the post" do
      let(:pundit_user) { SellerContext.new(user: @user, seller: @user) }

      it "returns true for an unpublished post" do
        presenter = PostPresenter.new(pundit_user:, post: unpublished_post, purchase_id_param: nil)
        expect(presenter.e404?).to be(true)
      end

      it "returns true for an published post that has been deleted" do
        post = create(:published_installment, seller: @user, shown_on_profile: true, deleted_at: Time.current)
        presenter = PostPresenter.new(pundit_user:, post:, purchase_id_param: nil)
        expect(presenter.e404?).to be(true)
      end

      it "returns false for a shown_on_profile=false post" do
        presenter = PostPresenter.new(pundit_user:, post: hidden_post, purchase_id_param: nil)
        expect(presenter.e404?).to be(false)
      end

      it "returns false for a workflow post" do
        presenter = PostPresenter.new(pundit_user:, post: workflow_post, purchase_id_param: nil)
        expect(presenter.e404?).to be(false)
      end
    end

    context "when a customer without a relevant purchase is viewing the post" do
      let(:user) { create(:purchase, link: create(:product, user: @creator)).purchaser }
      let(:pundit_user) { SellerContext.new(user:, seller: user) }

      it "returns true for a product-type post" do
        presenter = PostPresenter.new(pundit_user:, post: @product_post, purchase_id_param: nil)
        expect(presenter.e404?).to be(true)
      end

      it "returns true for a seller-type shown-on-profile post" do
        presenter = PostPresenter.new(pundit_user:, post: seller_post, purchase_id_param: nil)
        expect(presenter.e404?).to be(true)
      end
    end

    context "when a non-customer is viewing the post" do
      let(:user) { create(:user) }
      let(:pundit_user) { SellerContext.new(user:, seller: user) }

      it "returns true for a shown_on_profile=false post" do
        presenter = PostPresenter.new(pundit_user:, post: hidden_post, purchase_id_param: nil)
        expect(presenter.e404?).to be(true)
      end
    end

    context "when an unauthenticated user is viewing the post" do
      let(:pundit_user) { SellerContext.logged_out }

      it "returns true with a refunded purchase's param" do
        purchase = create(:refunded_purchase, link: @product)
        presenter = PostPresenter.new(pundit_user:, post: @product_post, purchase_id_param: purchase.external_id)
        expect(presenter.e404?).to be(true)
      end

      it "returns true with a chargedback purchase's param" do
        purchase = create(:purchase, link: @product, chargeback_date: Date.today)
        presenter = PostPresenter.new(pundit_user:, post: @product_post, purchase_id_param: purchase.external_id)
        expect(presenter.e404?).to be(true)
      end

      it "returns true with a purchase param that should not have access to a product-type post" do
        purchase = create(:purchase, link: create(:product, user: @creator)) # another of the seller's products
        presenter = PostPresenter.new(pundit_user:, post: @product_post, purchase_id_param: purchase.external_id)
        expect(presenter.e404?).to be(true)
      end

      it "returns true with a purchase param that should not have access to a seller-type shown-on-profile post" do
        purchase = create(:purchase, link: create(:product, user: @creator)) # another of the seller's products
        presenter = PostPresenter.new(pundit_user:, post: seller_post, purchase_id_param: purchase.external_id)
        expect(presenter.e404?).to be(true)
      end

      it "returns false with a valid purchase's param" do
        purchase = create(:purchase, link: @product)
        presenter = PostPresenter.new(pundit_user:, post: @product_post, purchase_id_param: purchase.external_id)
        expect(presenter.e404?).to be(false)
      end
    end
  end
end
