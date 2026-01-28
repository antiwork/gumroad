# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe UsersController do
  render_views

  let(:creator) { create(:user, username: "creator") }
  let(:seller) { create(:named_seller) }

  describe "GET current_user_data" do
    context "when user is signed in" do
      before do
        sign_in seller
      end

      it "returns success with user data" do
        timezone_name = "America/Los_Angeles"
        timezone_offset = ActiveSupport::TimeZone[timezone_name].tzinfo.utc_offset

        get :current_user_data

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be true
        expect(response.parsed_body["user"]).to include(
          "id" => seller.external_id,
          "email" => seller.email,
          "name" => seller.display_name,
          "subdomain" => seller.subdomain,
          "avatar_url" => seller.avatar_url,
          "is_buyer" => seller.is_buyer?,
          "time_zone" => {
            "name" => timezone_name,
            "offset" => timezone_offset
          }
        )
      end
    end

    context "when user is not signed in" do
      it "returns unauthorized" do
        get :current_user_data

        expect(response).to have_http_status(:unauthorized)
        json = JSON.parse(response.body)
        expect(json["success"]).to be false
      end
    end
  end

  describe "#show" do
    it "404s if user isn't found in HTML format" do
      expect { get :show, params: { username: "creator" }, format: :html }
        .to raise_error(ActionController::RoutingError)
    end

    it "404s if user isn't found in JSON format" do
      get :show, params: { username: "creator" }, format: :json

      expect(response.status).to eq(404)
    end

    it "404s if no username is passed" do
      expect { get :show }.to raise_error(ActionController::RoutingError)
    end

    it "404s if the the extension isn't html or json" do
      create(:product, user: create(:user, username: "creator"), name: "onelolol")
      @request.host = "creator.test.gumroad.com"
      expect do
        get :show, params: { username: "creator", format: "txt" }
      end.to raise_error(ActionController::RoutingError)
    end

    it "sets a global affiliate cookie if affiliate_id is set in params" do
      affiliate = create(:user).global_affiliate
      user = create(:named_user)

      # skip redirection to profile page
      stub_const("ROOT_DOMAIN", "test.gumroad.com")
      @request.host = "#{user.username}.test.gumroad.com"

      get :show, params: { username: user.username, affiliate_id: affiliate.external_id_numeric }

      expect(response.cookies[affiliate.cookie_key]).to be_present
    end

    context "when the user is deleted" do
      let(:creator) { create(:user, username: "creator", deleted_at: Time.current) }

      it "returns 404" do
        expect do
          get :show, params: { username: creator.username }
        end.to raise_error(ActionController::RoutingError)
      end
    end

    it "returns user json when json request is sent" do
      link = create(:product, user: create(:user, username: "creator"), name: "onelolol")

      @request.host = "creator.test.gumroad.com"
      get :show, params: { username: "creator", format: "json" }
      expect(response.parsed_body).to eq(link.user.as_json)
    end

    describe "redirection to subdomain for profile pages" do
      before do
        @user = create(:named_user)
      end

      context "when the request is from gumroad domain" do
        it "redirects to subdomain profile page" do
          get :show, params: { username: @user.username, sort: "price_asc" }

          expect(response).to redirect_to @user.subdomain_with_protocol + "/?sort=price_asc"
          expect(response).to have_http_status(:moved_permanently)
        end
      end

      context "when the request is for the profile page on the custom domain" do
        before do
          create(:custom_domain, domain: "example.com", user: @user)
          @request.host = "example.com"
        end

        it "doesn't redirect to subdomain profile page" do
          get :show, params: { username: @user.username }

          expect(response).to be_successful
        end
      end

      context "when the request is for the profile page on the subdomain" do
        before do
          stub_const("ROOT_DOMAIN", "test.gumroad.com")
          @request.host = "#{@user.username}.test.gumroad.com"
        end

        it "doesn't redirect to subdomain profile page" do
          get :show, params: { username: @user.username }

          expect(response).to be_successful
        end
      end
    end

    describe "from subdomain" do
      before do
        stub_const("ROOT_DOMAIN", "test.gumroad.com")
      end

      context "when the subdomain is valid and present" do
        before do
          @user = create(:user, username: "testuser")
          create(:product, user: @user, name: "onelolol")
          @request.host = "testuser.test.gumroad.com"
          get :show
        end

        it "assigns the correct user based on the subdomain" do
          expect(assigns(:user)).to eq(@user)
        end

        it "renders the show template" do
          expect(response).to render_template(:show)
        end
      end

      context "when the subdomain doesn't exist" do
        before do
          @request.host = "invalid.test.gumroad.com"
        end

        it "renders 404" do
          expect { get :show }.to raise_error(ActionController::RoutingError)
        end
      end
    end

    describe "from custom domain" do
      before do
        allow(Resolv::DNS).to receive_message_chain(:new, :getresources).and_return([double(name: "domains.gumroad.com")])
      end

      describe "when the custom domain is valid" do
        before do
          @user = create(:user, username: "dude")
          create(:product, user: @user, name: "onelolol")
          @domain = CustomDomain.create(domain: "www.example1.com", user: @user)
          @request.host = "www.example1.com"
          get :show
        end

        it "assigns the correct user based on the host" do
          expect(assigns(:user)).to eq(@user)
        end


        it "renders the show template" do
          expect(response).to render_template(:show)
        end

        describe "when the host is another subdomain that is www with the same apex domain" do
          before do
            @request.host = "www.example1.com"
            get :show
          end

          it "correctly sets the user based on the apex domain" do
            expect(assigns(:user)).to eq(@user)
          end

          it "renders the show template" do
            expect(response).to render_template(:show)
          end
        end

        describe "when the host is another subdomain that is not www with the same apex domain" do
          before do
            @request.host = "store.example1.com"
          end

          it "404s" do
            expect { get :show }.to raise_error(ActionController::RoutingError)
          end
        end
      end

      describe "when the domain requested is not saved as a custom domain" do
        before do
          @request.host = "not-example1.com"
        end

        it "404s" do
          expect { get :show }.to raise_error(ActionController::RoutingError)
        end
      end
    end

    it "sets paypal_merchant_currency as merchant account's currency if native paypal payments are enabled else as usd" do
      creator = create(:named_user)
      create(:product, user: creator)

      @request.host = "#{creator.username}.test.gumroad.com"
      get :show, params: { username: creator.username }
      expect(assigns[:paypal_merchant_currency]).to eq "USD"

      create(:merchant_account_paypal, user: creator, currency: "GBP")
      get :show, params: { username: creator.username }
      expect(assigns[:paypal_merchant_currency]).to eq "GBP"
    end

    context "with user signed in as admin for seller" do
      let(:seller) { create(:named_seller) }
      let(:creator) { create(:user, username: "creator") }

      include_context "with user signed in as admin for seller"

      it "assigns the correct instance variables" do
        expect(ProfilePresenter).to receive(:new).with(seller: creator, pundit_user: controller.pundit_user).at_least(:once).and_call_original

        @request.host = "#{creator.username}.test.gumroad.com"
        get :show, params: { username: creator.username }

        profile_props = assigns[:profile_props]
        expect(profile_props[:creator_profile][:external_id]).to eq(creator.external_id)
      end
    end

    describe "Elasticsearch queries cache", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      it "caches @search_results and tracks cache hits/misses" do
        metrics_key = "#{ProfileSectionsPresenter::CACHE_KEY_PREFIX}-metrics"
        $redis.del(metrics_key)
        user = create(:user, username: "testuser")
        product = create(:product, user:)
        create(:seller_profile_products_section, seller: user, shown_products: [product.id])
        @request.host = "testuser.test.gumroad.com"

        get :show
        expect($redis.hgetall(metrics_key)).to eq("misses" => "1")

        get :show
        expect($redis.hgetall(metrics_key)).to eq("misses" => "1", "hits" => "1")

        product.update!(name: "something else")

        get :show
        expect($redis.hgetall(metrics_key)).to eq("misses" => "2", "hits" => "1")
      end
    end

    it "truncates the bio when it's longer than 300 characters" do
      @request.host = seller.subdomain
      seller.update!(bio: "f" * 301)
      get :show, params: { username: seller.username }
      expect(response.body).to have_selector("meta[name='description'][content='#{"f" * 300}']", visible: false)
    end
  end

  describe "GET coffee" do
    let(:seller) { create(:user, :eligible_for_service_products) }
    render_views

    context "user has coffee product" do
      let!(:product) { create(:product, name: "Buy me a coffee", user: seller, native_type: Link::NATIVE_TYPE_COFFEE, purchase_disabled_at: Time.current) }

      it "responds successfully and sets the title" do
        get :coffee, params: { username: seller.username }

        expect(response).to be_successful
        expect(response.body).to have_selector("title:contains('Buy me a coffee')", visible: false)
      end
    end

    context "user doesn't have coffee product" do
      let!(:product) { create(:coffee_product, user: seller, archived: true) }

      it "returns a 404" do
        expect do
          get :coffee, params: { username: seller.username }
        end.to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe "GET session_info" do
    context "when user is not signed in" do
      it "returns json with is_signed_in: false" do
        get :session_info

        expect(response).to be_successful
        expect(response.parsed_body["is_signed_in"]).to eq false
      end
    end

    context "when user is signed in" do
      before do
        sign_in create(:user)
      end

      it "returns json with is_signed_in: true" do
        get :session_info

        expect(response).to be_successful
        expect(response.parsed_body["is_signed_in"]).to eq true
      end
    end
  end

  describe "#deactivate" do
    let(:user) { create(:user, username: "ohai") }

    it "redirects if user is not authenticated" do
      post :deactivate
      expect(response).to redirect_to login_url(next: request.path)
      expect(user.reload.deleted_at).to be(nil)
    end

    context "when user is authenticated" do
      context "when current user doesn't match current seller" do
        let (:other_user) { create(:user) }

        include_context "with user signed in as admin for seller"

        it "redirects" do
          post :deactivate
          expect(response).to redirect_to dashboard_path
          expect(flash[:alert]).to eq("Your current role as Admin cannot perform this action.")
          expect(user.deleted_at).to be(nil)
        end
      end

      context "when current user matches current seller" do
        before :each do
          sign_in user
        end

        it_behaves_like "authorize called for action", :post, :deactivate do
          let(:record) { user }
          let(:policy_method) { :deactivate? }
        end

        context "when user is successfully deactivated" do
          it "signs user out" do
            expect(controller).to receive(:sign_out)
            post :deactivate
          end

          it "succeeds" do
            post :deactivate
            expect(response.parsed_body["success"]).to be(true)
          end

          it "deletes all of the users products, product files, bank accounts, credit card, compliance infos.", :vcr, :elasticsearch_wait_for_refresh, :sidekiq_inline do
            create(:user_compliance_info, user:, individual_tax_id: "123456789")
            create(:ach_account, user:)
            link = create(:product, user:)
            link.product_files << create(:product_file, link:)
            link.product_files << create(:product_file, link:, is_linked_to_existing_file: true)
            link2 = create(:product, user:)
            link2.product_files << create(:product_file, link: link2)
            link2.product_files << create(:product_file, link: link2, is_linked_to_existing_file: true)
            create(:purchase, link: link2, purchase_state: "successful")
            user.credit_card = create(:credit_card)
            user.save!
            expect(user.reload.deleted_at).to be(nil)
            expect(user.user_compliance_infos.alive.size).to eq(1)
            expect(user.bank_accounts.alive.size).to eq(1)
            expect(user.links.alive.size).to eq(2)
            expect(link.product_files.alive.size).to eq(2)
            expect(link2.product_files.alive.size).to eq(2)
            expect(user.credit_card_id).not_to be(nil)

            post :deactivate

            [link, link2, user].each(&:reload)
            expect(user.deleted_at).not_to be(nil)
            expect(user.user_compliance_infos.alive.size).to eq(0)
            expect(user.bank_accounts.alive.size).to eq(0)
            expect(user.links.alive.size).to eq(0)
            expect(link.product_files.alive.size).to eq(0)
            expect(link2.product_files.alive.size).to eq(2)
            expect(user.credit_card_id).to be(nil)
          end

          it "deactivates the user account only if balance amount is 0" do
            create(:balance, user:, amount_cents: 10)
            create(:balance, user:, amount_cents: 11, date: 1.day.ago)
            post :deactivate
            expect(response.parsed_body["success"]).to eq(false)
            expect(user.reload.deleted_at).to be(nil)

            create(:balance, user:, amount_cents: -30, date: 2.days.ago)
            post :deactivate
            expect(response.parsed_body["success"]).to eq(false)
            expect(user.reload.deleted_at).to be(nil)

            create(:balance, user:, amount_cents: 9, date: 3.days.ago)
            post :deactivate
            expect(response.parsed_body["success"]).to eq(true)
            expect(user.reload.deleted_at).not_to be(nil)
          end

          it "sets deleted_at to non nil value" do
            post :deactivate
            expect(user.reload.deleted_at).to_not be(nil)
          end

          it "frees up the username" do
            post :deactivate
            expect(user.reload.read_attribute(:username)).to be(nil)
          end

          it "pauses payouts" do
            post :deactivate
            expect(user.reload.payouts_paused_internally?).to be(true)
          end

          it "logs out the user from all active sessions" do
            travel_to(DateTime.current) do
              expect do
                post :deactivate
              end.to change { user.reload.last_active_sessions_invalidated_at }.from(nil).to(DateTime.current)
            end
          end
        end

        context "when user is not successfully deactivated" do
          before :each do
            allow(controller.logged_in_user).to receive(:update!).and_raise
          end

          it "fails" do
            post :deactivate
            expect(response.parsed_body["success"]).to be(false)
          end

          it "does not set deleted_at to non nil value" do
            post :deactivate
            expect(user.reload.deleted_at).to be(nil)
          end
        end

        context "when the user has unpaid balances" do
          before :each do
            @balance = create(:balance, user:, amount_cents: 656)
          end

          context "when feature delete_account_forfeit_balance is active" do
            before do
              stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id) # For negative credits
              Feature.activate_user(:delete_account_forfeit_balance, user)
            end

            it "succeeds" do
              post :deactivate
              expect(user.reload.deleted_at).to_not be(nil)
              expect(@balance.reload.state).to eq("forfeited")
            end
          end

          context "when feature delete_account_forfeit_balance is inactive" do
            it "fails" do
              post :deactivate
              expect(response.parsed_body["success"]).to be(false)
              expect(user.reload.deleted_at).to be(nil)
              expect(user.unpaid_balance_cents).to eq(656)
              expect(@balance.reload.state).to eq("unpaid")
            end
          end
        end
      end
    end
  end

  describe "#email_unsubscribe" do
    before do
      @user = create(:user, enable_payment_email: true, weekly_notification: true)
    end

    context "with secure external id" do
      it "allows access with valid secure external id" do
        secure_id = @user.secure_external_id(scope: "email_unsubscribe")
        get :email_unsubscribe, params: { email_type: "notify", id: secure_id }
        expect(@user.reload.enable_payment_email).to be(false)
        expect(response).to redirect_to(root_path)
      end
    end

    context "with regular external id when user exists" do
      it "redirects to secure redirect page for confirmation" do
        get :email_unsubscribe, params: { email_type: "notify", id: @user.external_id }

        expect(response).to be_redirect
        expect(response.location).to start_with(secure_url_redirect_url)
        expect(response.location).to include("encrypted_payload")
        expect(response.location).to include("message=Please+enter+your+email+address+to+unsubscribe")
        expect(response.location).to include("field_name=Email+address")
        expect(response.location).to include("error_message=Email+address+does+not+match")
      end

      it "includes correct destination URL in redirect params" do
        allow(SecureEncryptService).to receive(:encrypt).and_call_original

        get :email_unsubscribe, params: { email_type: "seller_update", id: @user.external_id }

        expect(SecureEncryptService).to have_received(:encrypt).once
        # Verify that the encrypted payload contains the expected data
        encrypted_payload = URI.decode_www_form(URI.parse(response.location).query).to_h["encrypted_payload"]
        decrypted_payload = JSON.parse(SecureEncryptService.decrypt(encrypted_payload))
        expect(decrypted_payload["destination"]).to match(%r{/unsubscribe/.*email_type=seller_update})
        expect(decrypted_payload["confirmation_texts"]).to include(@user.email)
      end

      it "includes encrypted user email for confirmation" do
        allow(SecureEncryptService).to receive(:encrypt).and_call_original

        get :email_unsubscribe, params: { email_type: "product_update", id: @user.external_id }

        expect(SecureEncryptService).to have_received(:encrypt).once
        # Verify that the encrypted payload contains the expected data
        encrypted_payload = URI.decode_www_form(URI.parse(response.location).query).to_h["encrypted_payload"]
        decrypted_payload = JSON.parse(SecureEncryptService.decrypt(encrypted_payload))
        expect(decrypted_payload["confirmation_texts"]).to include(@user.email)
      end
    end

    context "with signed in user matching the external id" do
      it "allows access without redirect" do
        sign_in(@user)
        get :email_unsubscribe, params: { email_type: "notify", id: @user.external_id }
        expect(@user.reload.enable_payment_email).to be(false)
        expect(response).to redirect_to(root_path)
      end
    end

    context "with invalid external id" do
      it "raises 404 error" do
        expect do
          get :email_unsubscribe, params: { email_type: "notify", id: "invalid_id" }
        end.to raise_error(ActionController::RoutingError)
      end
    end

    describe "payment_notifications" do
      it "redirects home, sets column correctly" do
        secure_id = @user.secure_external_id(scope: "email_unsubscribe")
        get :email_unsubscribe, params: { email_type: "notify", id: secure_id }
        expect(@user.reload.enable_payment_email).to be(false)
      end
    end

    describe "weekly notifications" do
      it "redirects home, sets column correctly" do
        secure_id = @user.secure_external_id(scope: "email_unsubscribe")
        get :email_unsubscribe, params: { email_type: "seller_update", id: secure_id }
        expect(@user.reload.weekly_notification).to be(false)
      end
    end

    describe "announcement notifications" do
      it "redirects home, sets column correctly" do
        secure_id = @user.secure_external_id(scope: "email_unsubscribe")
        get :email_unsubscribe, params: { email_type: "product_update", id: secure_id }
        expect(@user.reload.announcement_notification_enabled).to be(false)
      end
    end
  end

  describe "#add_purchase_to_library" do
    before do
      @user = create(:user, username: "dude", password: "password")
      @purchase = create(:purchase, email: @user.email)
      @params = {
        "user" => {
          "password" => "password",
          "purchase_id" => @purchase.external_id,
          "purchase_email" => @purchase.email
        }
      }
    end

    it "associates the purchase to the signed_in user" do
      sign_in(@user)
      post :add_purchase_to_library, params: @params
      expect(@purchase.reload.purchaser).to eq @user
    end

    it "associates the purchase to the user if the password is correct" do
      post :add_purchase_to_library, params: @params
      expect(@purchase.reload.purchaser).to eq @user
    end

    it "doesn't associate the purchase with the user if the password is incorrect" do
      @params["user"]["password"] = "wrong password"
      post :add_purchase_to_library, params: @params
      expect(@purchase.reload.purchaser).to be(nil)
    end

    it "doesn't associate the purchase if the email doesn't match" do
      @params["user"]["purchase_email"] = "wrong@example.com"
      post :add_purchase_to_library, params: @params
      expect(@purchase.reload.purchaser).to be(nil)
    end

    context "when two factor authentication is enabled for the user" do
      before do
        @user.two_factor_authentication_enabled = true
        @user.save!
      end

      it "invokes sign_in_or_prepare_for_two_factor_auth" do
        expect(controller).to receive(:sign_in_or_prepare_for_two_factor_auth).with(@user).and_call_original

        @params["user"]["password"] = "password"
        post :add_purchase_to_library, params: @params
      end

      it "redirects to two_factor_authentication_with with next param set to library path" do
        @params["user"]["password"] = "password"
        post :add_purchase_to_library, params: @params

        expect(response.parsed_body["success"]).to eq true
        expect(response.parsed_body["redirect_location"]).to eq two_factor_authentication_path(next: library_path)
      end
    end
  end

  describe "GET subscribe" do
    context "with user signed in as admin for seller" do
      include_context "with user signed in as admin for seller"

      it "assigns the correct instance variables" do
        @request.host = "#{creator.username}.test.gumroad.com"
        get :subscribe

        expect(controller.send(:page_title)).to eq("Subscribe to creator")
        profile_presenter = assigns[:profile_presenter]
        expect(profile_presenter.seller).to eq(creator)
        expect(profile_presenter.pundit_user).to eq(controller.pundit_user)
      end
    end
  end

  describe "GET subscribe_preview" do
    it "assigns subscribe preview props for the react component" do
      get :subscribe_preview, params: { username: creator.username }
      expect(response).to be_successful
      expect(assigns[:subscribe_preview_props][:title]).to eq(creator.name_or_username)
      expect(assigns[:subscribe_preview_props][:avatar_url]).to end_with(".png")
    end
  end
end
