# frozen_string_literal: true

require "test_helper"
require "shared_examples/authorize_called"

class UsersControllerTest < ActionController::TestCase
  self.described_class = UsersController
  tests UsersController



  context_ UsersController do
    render_views

    let(:creator) { create(:user, username: "creator") }
    let(:seller) { create(:named_seller) }

  context_ "GET current_user_data" do
  context_ "when user is signed in" do
        before do
          sign_in seller
        end

  test "returns success with user data" do
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

  context_ "when user is not signed in" do
  test "returns unauthorized" do
          get :current_user_data

          expect(response).to have_http_status(:unauthorized)
          json = JSON.parse(response.body)
          expect(json["success"]).to be false
        end
      end
    end

  context_ "#show" do
  test "404s if user isn't found in HTML format" do
        expect { get :show, params: { username: "creator" }, format: :html }
          .to raise_error(ActionController::RoutingError)
      end

  test "404s if user isn't found in JSON format" do
        get :show, params: { username: "creator" }, format: :json

        expect(response.status).to eq(404)
      end

  test "404s if no username is passed" do
        expect { get :show }.to raise_error(ActionController::RoutingError)
      end

  test "404s if the the extension isn't html or json" do
        create(:product, user: create(:user, username: "creator"), name: "onelolol")
        @request.host = "creator.test.gumroad.com"
        expect do
          get :show, params: { username: "creator", format: "txt" }
        end.to raise_error(ActionController::RoutingError)
      end

  test "sets a global affiliate cookie if affiliate_id is set in params" do
        affiliate = create(:user).global_affiliate
        user = create(:named_user)

        # skip redirection to profile page
        stub_const("ROOT_DOMAIN", "test.gumroad.com")
        @request.host = "#{user.username}.test.gumroad.com"

        get :show, params: { username: user.username, affiliate_id: affiliate.external_id_numeric }

        expect(response.cookies[affiliate.cookie_key]).to be_present
      end

  context_ "when the user is deleted" do
        let(:creator) { create(:user, username: "creator", deleted_at: Time.current) }

  test "returns 404" do
          expect do
            get :show, params: { username: creator.username }
          end.to raise_error(ActionController::RoutingError)
        end
      end

  test "returns user json when json request is sent" do
        link = create(:product, user: create(:user, username: "creator"), name: "onelolol")

        @request.host = "creator.test.gumroad.com"
        get :show, params: { username: "creator", format: "json" }
        expect(response.parsed_body).to eq(link.user.as_json)
      end

  context_ "redirection to subdomain for profile pages" do
        before do
          @user = create(:named_user)
        end

  context_ "when the request is from gumroad domain" do
  test "redirects to subdomain profile page" do
            get :show, params: { username: @user.username, sort: "price_asc" }

            expect(response).to redirect_to @user.subdomain_with_protocol + "/?sort=price_asc"
            expect(response).to have_http_status(:moved_permanently)
          end
        end

  context_ "when the request is for the profile page on the custom domain" do
          before do
            create(:custom_domain, domain: "example.com", user: @user)
            @request.host = "example.com"
          end

  test "doesn't redirect to subdomain profile page" do
            get :show, params: { username: @user.username }

            expect(response).to be_successful
          end
        end

  context_ "when the request is for the profile page on the subdomain" do
          before do
            stub_const("ROOT_DOMAIN", "test.gumroad.com")
            @request.host = "#{@user.username}.test.gumroad.com"
          end

  test "doesn't redirect to subdomain profile page" do
            get :show, params: { username: @user.username }

            expect(response).to be_successful
          end
        end
      end

  context_ "from subdomain" do
        before do
          stub_const("ROOT_DOMAIN", "test.gumroad.com")
        end

  context_ "when the subdomain is valid and present" do
          before do
            @user = create(:user, username: "testuser")
            create(:product, user: @user, name: "onelolol")
            @request.host = "testuser.test.gumroad.com"
            get :show
          end

  test "assigns the correct user based on the subdomain" do
            expect(assigns(:user)).to eq(@user)
          end

  test "renders the Inertia Users/Show page", inertia: true do
            expect(response).to be_successful
            expect(inertia.component).to eq("Users/Show")
          end
        end

  context_ "when the subdomain doesn't exist" do
          before do
            @request.host = "invalid.test.gumroad.com"
          end

  test "renders 404" do
            expect { get :show }.to raise_error(ActionController::RoutingError)
          end
        end
      end

  context_ "from custom domain" do
        before do
          allow(Resolv::DNS).to receive_message_chain(:new, :getresources).and_return([double(name: "domains.gumroad.com")])
        end

  context_ "when the custom domain is valid" do
          before do
            @user = create(:user, username: "dude")
            create(:product, user: @user, name: "onelolol")
            @domain = CustomDomain.create(domain: "www.example1.com", user: @user)
            @request.host = "www.example1.com"
            get :show
          end

  test "assigns the correct user based on the host" do
            expect(assigns(:user)).to eq(@user)
          end


  test "renders the Inertia Users/Show page", inertia: true do
            expect(response).to be_successful
            expect(inertia.component).to eq("Users/Show")
          end

  context_ "when the host is another subdomain that is www with the same apex domain" do
            before do
              @request.host = "www.example1.com"
              get :show
            end

  test "correctly sets the user based on the apex domain" do
              expect(assigns(:user)).to eq(@user)
            end

  test "renders the Inertia Users/Show page", inertia: true do
              expect(response).to be_successful
              expect(inertia.component).to eq("Users/Show")
            end
          end

  context_ "when the host is another subdomain that is not www with the same apex domain" do
            before do
              @request.host = "store.example1.com"
            end

  test "404s" do
              expect { get :show }.to raise_error(ActionController::RoutingError)
            end
          end
        end

  context_ "when the domain requested is not saved as a custom domain" do
          before do
            @request.host = "not-example1.com"
          end

  test "404s" do
            expect { get :show }.to raise_error(ActionController::RoutingError)
          end
        end

  context_ "facebook-domain-verification meta tag" do
          before do
            @user = create(:user, username: "fbverify")
            create(:product, user: @user)
            CustomDomain.create(domain: "fb-verify.example.com", user: @user)
            @request.host = "fb-verify.example.com"
          end

  test "renders the meta tag with the content extracted from the seller's facebook_meta_tag" do
            @user.update!(
              enable_verify_domain_third_party_services: true,
              facebook_meta_tag: '<meta name="facebook-domain-verification" content="abc123verifycode" />'
            )

            get :show

            expect(response.body).to include('content="abc123verifycode"')
            expect(response.body).not_to include('<meta name="facebook-domain-verification" inertia=')
          end

  test "does not render the meta tag when domain verification is disabled" do
            @user.update!(
              enable_verify_domain_third_party_services: false,
              facebook_meta_tag: '<meta name="facebook-domain-verification" content="abc123verifycode" />'
            )

            get :show

            expect(response.body).not_to include('name="facebook-domain-verification"')
          end
        end
      end

  context_ "with user signed in as admin for seller", inertia: true do
        let(:seller) { create(:named_seller) }
        let(:creator) { create(:user, username: "creator") }

        include_context "with user signed in as admin for seller"

  test "assigns the correct instance variables" do
          expect(ProfilePresenter).to receive(:new).with(seller: creator, pundit_user: controller.pundit_user).at_least(:once).and_call_original

          stub_const("ROOT_DOMAIN", "test.gumroad.com")
          @request.host = "#{creator.username}.test.gumroad.com"
          get :show, params: { username: creator.username }

          expect(inertia.props[:creator_profile][:external_id]).to eq(creator.external_id)
        end
      end

  context_ "Elasticsearch queries cache", :sidekiq_inline, :elasticsearch_wait_for_refresh do
  test "caches @search_results and tracks cache hits/misses" do
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

  test "truncates the bio when it's longer than 300 characters" do
        @request.host = seller.subdomain
        seller.update!(bio: "f" * 301)
        get :show, params: { username: seller.username }
        expect(response.body).to have_selector("meta[name='description'][content='#{"f" * 300}']", visible: false)
      end
    end

  context_ "GET coffee", inertia: true do
      let(:seller) { create(:user, :eligible_for_service_products) }

  context_ "user has coffee product" do
        let!(:product) { create(:product, name: "Buy me a coffee", user: seller, native_type: Link::NATIVE_TYPE_COFFEE, purchase_disabled_at: Time.current) }

  test "renders the Inertia Users/Coffee component with correct props" do
          get :coffee, params: { username: seller.username }

          expect(response).to be_successful
          expect(inertia.component).to eq("Users/Coffee")
          expect(inertia.props[:product][:name]).to eq("Buy me a coffee")
          expect(inertia.props[:creator_profile]).to be_present
        end

  test "redirects and sets the flash message when purchase_email is present" do
          get :coffee, params: { username: seller.username, purchase_email: "buyer@example.com" }

          expect(response).to redirect_to("/coffee")
          expect(flash[:notice]).to eq("Your purchase was successful! We sent a receipt to buyer@example.com.")
        end

  test "sets custom styles in page meta when user has custom_styles" do
          get :coffee, params: { username: seller.username }

          html = Nokogiri::HTML.parse(response.body)
          style_tag = html.at_css('style[inertia="custom_styles"]')
          expect(style_tag).to be_present
          decoded_content = CGI.unescapeHTML(style_tag.text)
          expect(decoded_content).to include(seller.seller_profile.custom_styles.to_s)
        end
      end

  context_ "user doesn't have coffee product" do
        let!(:product) { create(:coffee_product, user: seller, archived: true) }

  test "returns a 404" do
          expect do
            get :coffee, params: { username: seller.username }
          end.to raise_error(ActionController::RoutingError)
        end
      end
    end

  context_ "GET session_info" do
  context_ "when user is not signed in" do
  test "returns json with is_signed_in: false" do
          get :session_info

          expect(response).to be_successful
          expect(response.parsed_body["is_signed_in"]).to eq false
        end
      end

  context_ "when user is signed in" do
        before do
          sign_in create(:user)
        end

  test "returns json with is_signed_in: true" do
          get :session_info

          expect(response).to be_successful
          expect(response.parsed_body["is_signed_in"]).to eq true
        end
      end
    end

  context_ "#deactivate" do
      let(:user) { create(:user, username: "ohai") }

  test "redirects if user is not authenticated" do
        post :deactivate
        expect(response).to redirect_to login_url(next: request.path)
        expect(user.reload.deleted_at).to be(nil)
      end

  context_ "when user is authenticated" do
  context_ "when current user doesn't match current seller" do
          let (:other_user) { create(:user) }

          include_context "with user signed in as admin for seller"

  test "redirects" do
            post :deactivate
            expect(response).to redirect_to dashboard_path
            expect(flash[:alert]).to eq("Your current role as Admin cannot perform this action.")
            expect(user.deleted_at).to be(nil)
          end
        end

  context_ "when current user matches current seller" do
          before :each do
            sign_in user
          end

          it_behaves_like "authorize called for action", :post, :deactivate do
            let(:record) { user }
            let(:policy_method) { :deactivate? }
          end

  context_ "when user is successfully deactivated" do
  test "signs user out" do
              expect(controller).to receive(:sign_out)
              post :deactivate
            end

  test "succeeds" do
              post :deactivate
              expect(response.parsed_body["success"]).to be(true)
            end

  test "deletes all of the users products, product files, bank accounts, credit card, compliance infos.", :vcr, :elasticsearch_wait_for_refresh, :sidekiq_inline do
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

  test "deactivates the user account only if balance amount is 0" do
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

  test "sets deleted_at to non nil value" do
              post :deactivate
              expect(user.reload.deleted_at).not_to be(nil)
            end

  test "frees up the username" do
              post :deactivate
              expect(user.reload.read_attribute(:username)).to be(nil)
            end

  test "pauses payouts" do
              post :deactivate
              expect(user.reload.payouts_paused_internally?).to be(true)
            end

  test "logs out the user from all active sessions" do
              travel_to(DateTime.current) do
                expect do
                  post :deactivate
                end.to change { user.reload.last_active_sessions_invalidated_at }.from(nil).to(DateTime.current)
              end
            end
          end

  context_ "when user is not successfully deactivated" do
            before :each do
              allow(controller.logged_in_user).to receive(:update!).and_raise
            end

  test "fails" do
              post :deactivate
              expect(response.parsed_body["success"]).to be(false)
            end

  test "does not set deleted_at to non nil value" do
              post :deactivate
              expect(user.reload.deleted_at).to be(nil)
            end
          end

  context_ "when the user has unpaid balances" do
            before :each do
              @balance = create(:balance, user:, amount_cents: 656)
            end

  context_ "when feature delete_account_forfeit_balance is active" do
              before do
                stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id) # For negative credits
                Feature.activate_user(:delete_account_forfeit_balance, user)
              end

  test "succeeds" do
                post :deactivate
                expect(user.reload.deleted_at).not_to be(nil)
                expect(@balance.reload.state).to eq("forfeited")
              end
            end

  context_ "when feature delete_account_forfeit_balance is inactive" do
  test "fails" do
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

  context_ "#email_unsubscribe" do
      before do
        @user = create(:user, enable_payment_email: true, weekly_notification: true)
      end

  context_ "with secure external id" do
  test "allows access with valid secure external id" do
          secure_id = @user.secure_external_id(scope: "email_unsubscribe")
          get :email_unsubscribe, params: { email_type: "notify", id: secure_id }
          expect(@user.reload.enable_payment_email).to be(false)
          expect(response).to redirect_to(root_path)
        end
      end

  context_ "with regular external id when user exists" do
  test "redirects to secure redirect page for confirmation" do
          get :email_unsubscribe, params: { email_type: "notify", id: @user.external_id }

          expect(response).to be_redirect
          expect(response.location).to start_with(secure_url_redirect_url)
          expect(response.location).to include("encrypted_payload")
          expect(response.location).to include("message=Please+enter+your+email+address+to+unsubscribe")
          expect(response.location).to include("field_name=Email+address")
          expect(response.location).to include("error_message=Email+address+does+not+match")
        end

  test "includes correct destination URL in redirect params" do
          allow(SecureEncryptService).to receive(:encrypt).and_call_original

          get :email_unsubscribe, params: { email_type: "seller_update", id: @user.external_id }

          expect(SecureEncryptService).to have_received(:encrypt).once
          # Verify that the encrypted payload contains the expected data
          encrypted_payload = URI.decode_www_form(URI.parse(response.location).query).to_h["encrypted_payload"]
          decrypted_payload = JSON.parse(SecureEncryptService.decrypt(encrypted_payload))
          expect(decrypted_payload["destination"]).to match(%r{/unsubscribe/.*email_type=seller_update})
          expect(decrypted_payload["confirmation_texts"]).to include(@user.email)
        end

  test "includes encrypted user email for confirmation" do
          allow(SecureEncryptService).to receive(:encrypt).and_call_original

          get :email_unsubscribe, params: { email_type: "product_update", id: @user.external_id }

          expect(SecureEncryptService).to have_received(:encrypt).once
          # Verify that the encrypted payload contains the expected data
          encrypted_payload = URI.decode_www_form(URI.parse(response.location).query).to_h["encrypted_payload"]
          decrypted_payload = JSON.parse(SecureEncryptService.decrypt(encrypted_payload))
          expect(decrypted_payload["confirmation_texts"]).to include(@user.email)
        end
      end

  context_ "with signed in user matching the external id" do
  test "allows access without redirect" do
          sign_in(@user)
          get :email_unsubscribe, params: { email_type: "notify", id: @user.external_id }
          expect(@user.reload.enable_payment_email).to be(false)
          expect(response).to redirect_to(root_path)
        end
      end

  context_ "with invalid external id" do
  test "raises 404 error" do
          expect do
            get :email_unsubscribe, params: { email_type: "notify", id: "invalid_id" }
          end.to raise_error(ActionController::RoutingError)
        end
      end

  context_ "payment_notifications" do
  test "redirects home, sets column correctly" do
          secure_id = @user.secure_external_id(scope: "email_unsubscribe")
          get :email_unsubscribe, params: { email_type: "notify", id: secure_id }
          expect(@user.reload.enable_payment_email).to be(false)
        end
      end

  context_ "weekly notifications" do
  test "redirects home, sets column correctly" do
          secure_id = @user.secure_external_id(scope: "email_unsubscribe")
          get :email_unsubscribe, params: { email_type: "seller_update", id: secure_id }
          expect(@user.reload.weekly_notification).to be(false)
        end
      end

  context_ "announcement notifications" do
  test "redirects home, sets column correctly" do
          secure_id = @user.secure_external_id(scope: "email_unsubscribe")
          get :email_unsubscribe, params: { email_type: "product_update", id: secure_id }
          expect(@user.reload.announcement_notification_enabled).to be(false)
        end
      end
    end

  context_ "#add_purchase_to_library" do
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

  test "associates the purchase to the signed_in user" do
        sign_in(@user)
        post :add_purchase_to_library, params: @params
        expect(@purchase.reload.purchaser).to eq @user
      end

  test "associates the purchase to the user if the password is correct" do
        post :add_purchase_to_library, params: @params
        expect(@purchase.reload.purchaser).to eq @user
      end

  test "doesn't associate the purchase with the user if the password is incorrect" do
        @params["user"]["password"] = "wrong password"
        post :add_purchase_to_library, params: @params
        expect(@purchase.reload.purchaser).to be(nil)
      end

  test "doesn't associate the purchase if the email doesn't match" do
        @params["user"]["purchase_email"] = "wrong@example.com"
        post :add_purchase_to_library, params: @params
        expect(@purchase.reload.purchaser).to be(nil)
      end

  context_ "when two factor authentication is enabled for the user" do
        before do
          @user.two_factor_authentication_enabled = true
          @user.save!
        end

  test "invokes sign_in_or_prepare_for_two_factor_auth" do
          expect(controller).to receive(:sign_in_or_prepare_for_two_factor_auth).with(@user).and_call_original

          @params["user"]["password"] = "password"
          post :add_purchase_to_library, params: @params
        end

  test "redirects to two_factor_authentication_with with next param set to library path" do
          @params["user"]["password"] = "password"
          post :add_purchase_to_library, params: @params

          expect(response.parsed_body["success"]).to eq true
          expect(response.parsed_body["redirect_location"]).to eq two_factor_authentication_path(next: library_path)
        end
      end
    end

  context_ "GET subscribe", inertia: true do
      before do
        stub_const("ROOT_DOMAIN", "test.gumroad.com")
        @request.host = "#{creator.username}.test.gumroad.com"
      end

  test "renders the Inertia Users/Subscribe component with creator_profile only" do
        get :subscribe

        expect(response).to be_successful
        expect(inertia.component).to eq("Users/Subscribe")
        expect(inertia.props[:creator_profile]).to be_present
        expect(inertia.props).not_to have_key(:custom_styles)
      end

  test "sets custom styles in page meta when user has custom_styles" do
        get :subscribe

        html = Nokogiri::HTML.parse(response.body)
        style_tag = html.at_css('style[inertia="custom_styles"]')
        expect(style_tag).to be_present
        decoded_content = CGI.unescapeHTML(style_tag.text)
        expect(decoded_content).to include(creator.seller_profile.custom_styles.to_s)
      end

  test "does not set custom_styles meta when user has no custom_styles" do
        allow_any_instance_of(SellerProfile).to receive(:custom_styles).and_return("")

        get :subscribe

        html = Nokogiri::HTML.parse(response.body)
        style_tag = html.at_css('style[inertia="custom_styles"]')
        expect(style_tag).to be_nil
      end

  context_ "with user signed in as admin for seller" do
        include_context "with user signed in as admin for seller"

  test "assigns the correct page title and renders creator profile" do
          get :subscribe

          expect(controller.send(:page_title)).to eq("Subscribe to creator")
          expect(inertia.props[:creator_profile][:external_id]).to eq(creator.external_id)
        end
      end
    end

  context_ "GET subscribe_preview", inertia: true do
  test "assigns subscribe preview props for the react component" do
        get :subscribe_preview, params: { username: creator.username }
        expect(response).to be_successful
        expect(inertia.component).to eq("Users/SubscribePreview")
        expect(inertia.props[:title]).to eq(creator.name_or_username)
        expect(inertia.props[:avatar_url]).to end_with(".png")
      end

  test "sets custom styles in page meta when user has custom_styles" do
        get :subscribe_preview, params: { username: creator.username }

        html = Nokogiri::HTML.parse(response.body)
        style_tag = html.at_css('style[inertia="custom_styles"]')
        expect(style_tag).to be_present
        decoded_content = CGI.unescapeHTML(style_tag.text)
        expect(decoded_content).to include(creator.seller_profile.custom_styles.to_s)
      end
    end
  end
end
