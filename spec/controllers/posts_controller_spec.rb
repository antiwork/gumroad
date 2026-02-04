# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe PostsController, type: :controller, inertia: true do
  let(:seller) { create(:named_seller) }

  context "within seller area" do
    include_context "with user signed in as admin for seller"

    describe "GET redirect_from_purchase_id" do
      before do
        @product = create(:product, user: seller)
        @purchase = create(:purchase, link: @product)
      end

      let(:installment) { create(:published_installment, link: @product, installment_type: "product", shown_on_profile: false) }

      it_behaves_like "authorize called for action", :get, :redirect_from_purchase_id do
        let(:record) { Installment }
        let(:request_params) { { id: installment.external_id, purchase_id: @purchase.external_id } }
      end

      it "redirects old /library/purchase/purchase_id paths to the new path" do
        get :redirect_from_purchase_id, params: { id: installment.external_id, purchase_id: @purchase.external_id }
        expect(response).to redirect_to(view_post_path(
                                          username: installment.user.username.presence || installment.user.external_id,
                                          slug: installment.slug,
                                          purchase_id: @purchase.external_id))
      end
    end

    describe "GET send_for_purchase" do
      before do
        link = create(:product, user: seller)
        @post = create(:installment, link:)
        @purchase = create(:purchase, seller:, link:, created_at: Time.current)
        create(:creator_contacting_customers_email_info_delivered, installment: @post, purchase: @purchase)
      end

      before do
        create(:payment_completed, user: seller)
        allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
      end

      it_behaves_like "authorize called for action", :get, :send_for_purchase do
        let(:record) { Installment }
        let(:request_params) { { id: @post.external_id, purchase_id: @purchase.external_id } }
      end

      it "returns an error if seller is not eligible to send emails" do
        allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)

        @purchase.create_url_redirect!
        expect(PostSendgridApi).to_not receive(:process)
        get :send_for_purchase, params: { id: @post.external_id, purchase_id: @purchase.external_id }
        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body).to eq("message" => "You are not eligible to resend this email.")
      end

      it "returns 404 if no purchase" do
        expect(PostSendgridApi).to_not receive(:process)
        expect do
          get :send_for_purchase, params: { id: @post.external_id, purchase_id: "hello" }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "returns success and redelivers the installment" do
        @purchase.create_url_redirect!
        expect(PostSendgridApi).to receive(:process).with(
          post: @post,
          recipients: [{
            email: @purchase.email,
            purchase: @purchase,
            url_redirect: @purchase.url_redirect,
          }]
        )
        get :send_for_purchase, params: { id: @post.external_id, purchase_id: @purchase.external_id }
        expect(response).to be_successful
        expect(response).to have_http_status(:no_content)

        # when the purchase part of a subscription
        membership_purchase = create(:membership_purchase, link: create(:membership_product, user: @post.seller))
        membership_purchase.create_url_redirect!
        expect(PostSendgridApi).to receive(:process).with(
          post: @post,
          recipients: [{
            email: membership_purchase.email,
            purchase: membership_purchase,
            url_redirect: membership_purchase.url_redirect,
            subscription: membership_purchase.subscription,
          }]
        )
        get :send_for_purchase, params: { id: @post.external_id, purchase_id: membership_purchase.external_id }
        expect(response).to be_successful
        expect(response).to have_http_status(:no_content)
      end
    end
  end

  context "within consumer area" do
    before do
      sign_in seller
    end

    describe "GET 'show'" do
      render_views

      before do
        @user = create(:named_user)
        @product = create(:product, user: @user)
        @purchase = create(:purchase, link: @product)
        @request.host = URI.parse(@user.subdomain_with_protocol).host
      end

      it "renders a non-public product installment with a valid purchase_id" do
        installment = create(:published_installment, link: @product, installment_type: "product", shown_on_profile: false)
        get :show, params: { username: @user.username, slug: installment.slug, purchase_id: @purchase.external_id }
        expect(response).to be_successful
        expect(inertia).to render_component("Posts/Show")
        expect(inertia.props[:subject]).to eq(installment.subject)
        expect(inertia.props[:external_id]).to eq(installment.external_id)
        expect(inertia.props[:purchase_id]).to eq(@purchase.external_id)
        expect(inertia.props[:published_at]).to eq(installment.published_at)
        expect(inertia.props[:message]).to be_present
        expect(inertia.props[:call_to_action]).to be_nil
        expect(inertia.props[:download_url]).to be_nil
        expect(inertia.props[:has_posts_on_profile]).to eq(false)
        expect(inertia.props[:recent_posts]).to eq([])
        expect(inertia.props[:paginated_comments]).to be_present
        expect(inertia.props[:comments_max_allowed_depth]).to eq(Comment::MAX_ALLOWED_DEPTH)
        expect(inertia.props[:creator_profile]).to be_present
        expect(inertia.props[:custom_styles]).to eq(@user.seller_profile.custom_styles)
      end

      it "sets the post page meta tags" do
        installment = create(:published_installment, link: @product, installment_type: "product", shown_on_profile: false)
        get :show, params: { username: @user.username, slug: installment.slug, purchase_id: @purchase.external_id }
        html = Nokogiri::HTML.parse(response.body)
        post_presenter = PostPresenter.new(pundit_user: SellerContext.new(user: @user, seller:), post: installment, purchase_id_param: nil)
        expect(html.xpath("//meta[@name='description']/@content").text).to eq(post_presenter.snippet)
        expect(html.xpath("//meta[@property='og:title']/@value").text).to eq(installment.name)
        expect(html.xpath("//meta[@property='og:description']/@value").text).to eq(post_presenter.snippet)
        expect(html.xpath("//meta[@property='og:image']/@value").text).to eq ActionController::Base.helpers.image_path("opengraph_image.png")
        expect(html.xpath("//meta[@property='twitter:title']/@value").text).to eq(installment.name)
        expect(html.xpath("//meta[@property='twitter:description']/@value").text).to eq(post_presenter.snippet)
        expect(html.xpath("//meta[@property='twitter:domain']/@value").text).to eq("Gumroad")
        expect(html.xpath("//meta[@property='twitter:card']/@value").text).to eq("summary")
      end

      it "sets @user instance variable to load third-party analytics config" do
        installment = create(:published_installment, link: @product, installment_type: "product", shown_on_profile: false)
        get :show, params: { username: @user.username, slug: installment.slug, purchase_id: @purchase.external_id }

        expect(assigns[:user]).to eq installment.seller
      end

      context "with user signed in as support for seller" do
        include_context "with user signed in as support for seller"

        let(:product) { create(:product, user: seller) }
        let(:post) { create(:published_installment, link: product, installment_type: "product", shown_on_profile: true) }

        it "renders post" do
          get :show, params: { username: seller.username, slug: post.slug }
          expect(response).to be_successful
        end
      end

      it "renders a publicly visible installment even if it doesn't have a purchase_id" do
        installment = create(:published_installment, installment_type: Installment::AUDIENCE_TYPE, seller: @user, shown_on_profile: true)
        get :show, params: { username: @user.username, slug: installment.slug }
        expect(response).to be_successful
        expect(inertia).to render_component("Posts/Show")
      end

      it "does not render a non-public installment if it doesn't have a valid purchase_id" do
        installment = create(:published_installment, seller: @user, shown_on_profile: false)
        expect { get :show, params: { username: @user.username, slug: installment.slug } }.to raise_error(ActionController::RoutingError)
      end

      it "does not render a non-published installment" do
        installment = create(:installment, seller: @user, shown_on_profile: true)
        expect { get :show, params: { username: @user.username, slug: installment.slug } }.to raise_error(ActionController::RoutingError)
      end

      it "does not render a deleted published installment" do
        installment = create(:published_installment, seller: @user, shown_on_profile: true, deleted_at: Time.current)
        expect { get :show, params: { username: @user.username, slug: installment.slug } }.to raise_error(ActionController::RoutingError)
      end

      it "raises routing error if slug is invalid" do
        expect { get :show, params: { username: @user.username, slug: "invalid_slug" } }.to raise_error(ActionController::RoutingError)
      end

      it "does not show posts for suspended users" do
        admin_user = create(:admin_user)

        installment = create(:published_installment, seller: @user, shown_on_profile: true)
        @user.flag_for_fraud!(author_id: admin_user.id)
        @user.suspend_for_fraud!(author_id: admin_user.id)
        expect { get :show, params: { username: @user.username, slug: installment.slug } }.to raise_error(ActionController::RoutingError)

        user = create(:user)
        installment = create(:audience_installment, seller: user, shown_on_profile: true, published_at: Time.current)
        user.flag_for_fraud!(author_id: admin_user.id)
        user.suspend_for_fraud!(author_id: admin_user.id)
        expect { get :show, params: { username: user.username, slug: installment.slug } }.to raise_error(ActionController::RoutingError)
      end

      context "when requested through custom domain" do
        before do
          create(:custom_domain, user: @user, domain: "example.com")
          @post = create(:published_installment, installment_type: Installment::AUDIENCE_TYPE, seller: @user, shown_on_profile: true)
          @request.host = "example.com"
        end

        it "renders the post" do
          get :show, params: { slug: @post.slug }

          expect(assigns[:post]).to eq @post
          expect(response).to be_successful
          expect(inertia).to render_component("Posts/Show")
          expect(inertia.props[:subject]).to eq(@post.subject)
        end
      end

      context "when requested through app domain" do
        before do
          @request.host = DOMAIN
          @post = create(:published_installment, installment_type: Installment::AUDIENCE_TYPE, seller: @user, shown_on_profile: true)
        end

        it "redirects to subdomain url of the post" do
          get :show, params: { username: @user.username, slug: @post.slug, purchase_id: 123 }

          expect(request).to redirect_to custom_domain_view_post_url(slug: @post.slug, host: @user.subdomain_with_protocol, purchase_id: 123)
          expect(response).to have_http_status(:moved_permanently)
        end
      end
    end

    describe "increment_post_views" do
      describe "page view incrementor" do
        it "increments the post page view with a new Event and InstallmentEvent record" do
          user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_7_3) AppleWebKit/535.19 (KHTML, like Gecko) Chrome/18.0.1025.165 Safari/535.19"
          @request.env["HTTP_USER_AGENT"] = user_agent
          installment = create(:installment, name: "installment")
          post :increment_post_views, params: { id: installment.external_id }

          post_view_event = Event.post_view.last
          installment_event = InstallmentEvent.last
          expect(installment_event.installment_id).to be(installment.id)
          expect(installment_event.event_id).to be(post_view_event.id)
        end

        it "creates a post page view event associated with a link" do
          link = create(:product)
          installment = create(:installment, link:, installment_type: "product")
          post :increment_post_views, params: { id: installment.external_id, parent_referrer: "t.co/9ew9j9" }

          post_view_event = Event.post_view.last

          expect(post_view_event.parent_referrer).to eq "t.co/9ew9j9"
          expect(post_view_event.link_id).to eq link.id
        end

        it "increments the page view for other user" do
          user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_7_3) AppleWebKit/535.19 (KHTML, like Gecko) Chrome/18.0.1025.165 Safari/535.19"
          @request.env["HTTP_USER_AGENT"] = user_agent
          create(:user)
          another_user = create(:user)
          sign_in another_user
          installment = create(:installment)
          post :increment_post_views, params: { id: installment.external_id }

          post_view_event = Event.post_view.last
          expect(post_view_event.user_id).to eq another_user.id
        end

        it "increments the page view if user is anonymous" do
          user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_7_3) AppleWebKit/535.19 (KHTML, like Gecko) Chrome/18.0.1025.165 Safari/535.19"
          @request.env["HTTP_USER_AGENT"] = user_agent
          create(:user)
          sign_out seller
          installment = create(:installment)
          post :increment_post_views, params: { id: installment.external_id }

          post_view_event = Event.post_view.last
          installment_event = InstallmentEvent.last
          expect(installment_event.installment_id).to be(installment.id)
          expect(installment_event.event_id).to be(post_view_event.id)
        end

        it "does not increment page views for bots" do
          @request.env["HTTP_USER_AGENT"] = "EventMachine HttpClient"
          installment = create(:installment)
          post :increment_post_views, params: { id: installment.external_id }
          expect(Event.post_view.count).to be(0)
        end

        it "does not increment page views for same user" do
          user = create(:user)
          installment = create(:installment, seller: user)
          allow(controller).to receive(:current_user).and_return(user)
          post :increment_post_views, params: { id: installment.external_id }
          expect(Event.post_view.count).to be(0)
        end

        it "does not increment page views for admin user" do
          user = create(:admin_user)
          allow(controller).to receive(:current_user).and_return(user)
          installment = create(:installment)
          post :increment_post_views, params: { id: installment.external_id }
          expect(Event.post_view.count).to be(0)
        end

        context "with user signed in as admin for seller" do
          include_context "with user signed in as admin for seller"

          it "does not increment page views for team member" do
            # user = create(:admin_user)
            # allow(controller).to receive(:current_user).and_return(user)
            installment = create(:installment, seller:)
            post :increment_post_views, params: { id: installment.external_id }
            expect(Event.post_view.count).to be(0)
          end
        end

        it "does not increment page views for bots that pretends to be same user" do
          user = create(:user)
          allow(controller).to receive(:current_user).and_return(user)
          create(:product, user:)
          @request.env["HTTP_USER_AGENT"] = "EventMachine HttpClient"
          installment = create(:installment)
          post :increment_post_views, params: { id: installment.external_id }
          expect(Event.post_view.count).to be(0)
        end
      end
    end
  end
end
