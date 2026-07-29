# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe FollowersController, inertia: true do
  render_views

  let(:seller) { create(:named_seller) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }

  context "within seller area" do
    include_context "with user signed in as admin for seller"

    describe "GET index" do
      it "returns successful response with Inertia page data" do
        followers = create_list(:follower, 20, user: seller) do |follower, index|
          follower.update!(confirmed_at: Time.current - index.days)
        end
        create(:follower, user: seller, confirmed_at: Time.current - 30.days)
        create(:follower, user: seller)
        get :index
        expect(response).to be_successful
        expect(inertia.component).to eq("Followers/Index")
        expect(inertia.props).to match(hash_including(
          followers: followers.map { _1.as_json(pundit_user:) },
          total_count: 21,
          page: 1,
          has_more: true,
          email: "",
        ))
      end

      it "supports search via email query parameter" do
        create(:follower, user: seller, email: "test@example.com", confirmed_at: Time.current)
        create(:follower, user: seller, email: "other@example.com", confirmed_at: Time.current)
        get :index, params: { email: "test" }
        expect(response).to be_successful
        expect(inertia.component).to eq("Followers/Index")
        expect(inertia.props).to match(hash_including(
          total_count: 2,
          email: "test",
        ))
        expect(inertia.props[:followers].length).to eq(1)
        expect(inertia.props[:followers].first).to match(hash_including(email: "test@example.com"))
      end

      it "supports pagination via page query parameter" do
        create_list(:follower, 25, user: seller) do |follower|
          follower.update!(confirmed_at: Time.current)
        end
        get :index, params: { page: 2 }
        expect(response).to be_successful
        expect(inertia.props[:page]).to eq(2)
        expect(inertia.props[:followers].length).to eq(5)
        expect(inertia.props[:has_more]).to be(false)
      end

      it "combines search and pagination" do
        create_list(:follower, 25, user: seller) do |follower, index|
          follower.update!(email: "test#{index}@example.com", confirmed_at: Time.current)
        end
        get :index, params: { email: "test", page: 2 }
        expect(response).to be_successful
        expect(inertia.props[:email]).to eq("test")
        expect(inertia.props[:page]).to eq(2)
        expect(inertia.props[:total_count]).to eq(25)
      end
    end

    describe "DELETE destroy" do
      let(:follower) { create(:active_follower, user: seller) }

      it "marks follower as deleted and redirects with notice" do
        delete :destroy, params: { id: follower.external_id }
        expect(response).to redirect_to(followers_path)
        expect(flash[:notice]).to eq("Follower removed!")
        expect(follower.reload.deleted?).to be(true)
      end

      it "returns 404 when follower is invalid" do
        expect { delete :destroy, params: { id: "invalid follower" } }.to raise_error(ActionController::RoutingError)
      end
    end
  end

  context "within consumer area" do
    describe "GET new" do
      before do
        @user = create(:user, username: "dude")
        get :new, params: { username: @user.username }
      end

      it "redirects to user profile" do
        expect(response).to redirect_to(@user.profile_url)
      end
    end

    describe "POST create" do
      it "redirects to subscribe page with notice on success" do
        post :create, params: { email: "follower@example.com", seller_id: seller.external_id }
        expect(response).to redirect_to(custom_domain_subscribe_path)
        expect(response).to have_http_status(:see_other)
        expect(flash[:notice]).to eq("Check your inbox to confirm your follow request.")

        follower = Follower.last
        expect(follower.email).to eq "follower@example.com"
        expect(follower.user).to eq seller
      end

      it "redirects to subscribe page with alert when email is invalid" do
        post :create, params: { email: "invalid email", seller_id: seller.external_id }
        expect(response).to redirect_to(custom_domain_subscribe_path)
        expect(flash[:alert]).to include("Email invalid")
      end

      it "uncancels if follow object exists" do
        follower = create(:deleted_follower, email: "follower@example.com", followed_id: seller.id)
        expect { post :create, params: { email: "follower@example.com", seller_id: seller.external_id } }.to change {
          follower.reload.deleted?
        }.from(true).to(false)
      end

      describe "logged in" do
        before do
          @buyer = create(:user)
          @params = { seller_id: seller.external_id, email: @buyer.email }
          sign_in @buyer
        end

        it "redirects to subscribe page with notice on success" do
          post :create, params: @params
          expect(response).to redirect_to(custom_domain_subscribe_path)
          expect(response).to have_http_status(:see_other)
          expect(flash[:notice]).to eq("You are now following #{seller.name_or_username}!")
        end

        it "creates a new follower row" do
          expect { post :create, params: @params }.to change {
            Follower.count
          }.by(1)
        end
      end

      # Following a suspended seller must fail at the controller, before
      # Follower::CreateService is ever invoked: creating the Follower row is
      # what sends the "Please confirm your follow request" email, which a
      # phishing ring used as a relay to mail harvested addresses from
      # Gumroad's own domain — and kept using after the accounts were banned,
      # because this public POST endpoint never checked suspension. The
      # response must be indistinguishable from an unknown seller_id so the
      # endpoint doesn't disclose that an account is suspended.
      context "when the followed seller is suspended" do
        before do
          admin = create(:admin_user)
          seller.flag_for_fraud!(author_id: admin.id)
          seller.suspend_for_fraud!(author_id: admin.id)
        end

        it "creates no follower, sends no confirmation email, and never reaches the service" do
          expect(Follower::CreateService).not_to receive(:perform)

          expect do
            expect do
              post :create, params: { email: "stranger@example.com", seller_id: seller.external_id }
            end.not_to change { Follower.count }
          end.not_to have_enqueued_mail(FollowerMailer, :confirm_follower)
        end

        it "responds like an unknown seller (HTML)" do
          post :create, params: { email: "stranger@example.com", seller_id: seller.external_id }

          expect(response).to redirect_to(custom_domain_subscribe_path)
          expect(flash[:alert]).to eq("Sorry, something went wrong.")
        end

        it "responds like an unknown seller (JSON)" do
          post :create, params: { email: "stranger@example.com", seller_id: seller.external_id }, format: :json

          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.parsed_body).to eq("success" => false, "message" => "Sorry, something went wrong.")
        end
      end

      describe "create follow object with email, create a user with same email, and log in" do
        it "follow should update the existing follower and not create another one or throw an exception" do
          post :create, params: { email: "follower@example.com", seller_id: seller.external_id }

          expect(response).to redirect_to(custom_domain_subscribe_path)
          expect(response).to have_http_status(:see_other)
          expect(flash[:notice]).to eq("Check your inbox to confirm your follow request.")

          follower = Follower.last
          expect(follower.email).to eq "follower@example.com"
          expect(follower.user).to eq seller

          new_user = create(:user, email: "follower@example.com")
          sign_in new_user

          post :create, params: { email: "follower@example.com", seller_id: seller.external_id }
          expect(response).to redirect_to(custom_domain_subscribe_path)
          expect(response).to have_http_status(:see_other)
          expect(flash[:notice]).to eq("You are now following #{seller.name_or_username}!")

          expect(Follower.count).to be 1
          expect(Follower.last.follower_user_id).to be new_user.id
        end
      end

      describe "CAPTCHA gate" do
        # Rails.env.test? short-circuits the verification helper, so every other
        # spec in this file exercises the pass path. These stub it to prove the
        # gate exists and that it only applies to sellers we haven't reviewed.
        def fail_the_captcha
          allow_any_instance_of(described_class).to receive(:valid_recaptcha_response_and_hostname?).and_return(false)
        end

        it "refuses the follow and sends the visitor back to the subscribe page" do
          fail_the_captcha

          expect do
            post :create, params: { email: "follower@example.com", seller_id: seller.external_id }
          end.to_not change { Follower.count }

          expect(response).to redirect_to(custom_domain_subscribe_path)
          expect(flash[:alert]).to eq(ValidateRecaptcha::CAPTCHA_FAILURE_MESSAGE)
        end

        it "sends no confirmation email" do
          fail_the_captcha

          expect do
            post :create, params: { email: "follower@example.com", seller_id: seller.external_id }
          end.to_not have_enqueued_mail(FollowerMailer, :confirm_follower)
        end

        it "returns 422 with the failure message as JSON" do
          fail_the_captcha

          post :create, params: { email: "follower@example.com", seller_id: seller.external_id }, format: :json

          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["message"]).to eq(ValidateRecaptcha::CAPTCHA_FAILURE_MESSAGE)
        end

        it "asks for no CAPTCHA at all for a compliant seller" do
          seller.update!(user_risk_state: "compliant")
          expect_any_instance_of(described_class).to_not receive(:valid_recaptcha_response_and_hostname?)

          expect do
            post :create, params: { email: "follower@example.com", seller_id: seller.external_id }
          end.to change { Follower.count }.by(1)
        end

        it "verifies the CAPTCHA against the same key the follow form executes, and checks the hostname" do
          expect_any_instance_of(described_class).to receive(:valid_recaptcha_response_and_hostname?)
            .with(site_key: FollowRecaptcha.site_key, surface: FollowRecaptcha::SURFACE)
            .and_return(true)

          post :create, params: { email: "follower@example.com", seller_id: seller.external_id }

          expect(response).to have_http_status(:see_other)
        end
      end
    end

    describe "GET confirm" do
      let(:unconfirmed_follower) { create(:follower, user: seller) }

      it "confirms the follow" do
        get :confirm, params: { id: unconfirmed_follower.external_id }
        expect(response).to redirect_to(seller.profile_url)
        expect(unconfirmed_follower.reload.confirmed_at).to_not eq(nil)
      end

      it "returns 404 when follower is invalid" do
        expect { get :confirm, params: { id: "invalid follower" } }.to raise_error(ActionController::RoutingError)
      end

      it "returns 404 when seller is inactive" do
        seller.deactivate!
        expect do
          get :confirm, params: { id: unconfirmed_follower.external_id }
        end.to raise_error(ActionController::RoutingError)
      end
    end

    describe "POST from_embed_form" do
      # The embed form carries no CAPTCHA (see the unreviewed-seller context
      # below), so these specs describe the reviewed-and-compliant seller whose
      # embed form takes follows directly.
      before { seller.update!(user_risk_state: "compliant") }

      it "creates a follower object" do
        post :from_embed_form, params: { email: "follower@example.com", seller_id: seller.external_id }
        follower = Follower.last
        expect(follower.email).to eq "follower@example.com"
        expect(follower.user).to eq seller
      end

      it "renders Inertia page with success message" do
        post :from_embed_form, params: { email: "follower@example.com", seller_id: seller.external_id }
        expect(response).to be_successful
        expect(inertia.component).to eq("Followers/FromEmbedForm")
        expect(inertia.props[:success]).to be(true)
        expect(inertia.props[:message]).to eq("Check your inbox to confirm your follow request.")
      end

      it "redirects to seller profile with flash warning on failure" do
        post :from_embed_form, params: { email: "exampleexample.com", seller_id: seller.external_id }
        expect(response).to redirect_to(seller.profile_url)
        expect(flash[:warning]).to be_present
        expect(flash[:warning]).to include("Email invalid")
      end

      context "when a user is already following the creator using the same email" do
        let(:following_user) { create(:user, email: "follower@example.com") }
        let!(:following_relationship) { create(:active_follower, user: seller, email: following_user.email, follower_user_id: following_user.id, source: Follower::From::PROFILE_PAGE) }

        it "does not create a new follower object; preserves the existing following relationship" do
          expect do
            post :from_embed_form, params: { email: following_user.email, seller_id: seller.external_id }
          end.not_to change { Follower.count }

          expect(following_relationship.follower_user_id).to eq(following_user.id)
          expect(response).to be_successful
          expect(inertia.component).to eq("Followers/FromEmbedForm")
          expect(inertia.props[:success]).to be(true)
          expect(inertia.props[:message]).to eq("You are now following #{seller.name_or_username}!")
        end
      end

      # Same suspension guard as POST create: from_embed_form goes through the
      # shared create_follower helper, and the embed form is just as reachable
      # by a bot as the main /follow endpoint.
      context "when the followed seller is suspended" do
        before do
          admin = create(:admin_user)
          seller.flag_for_fraud!(author_id: admin.id)
          seller.suspend_for_fraud!(author_id: admin.id)
        end

        it "creates no follower and sends no confirmation email" do
          expect(Follower::CreateService).not_to receive(:perform)

          expect do
            expect do
              post :from_embed_form, params: { email: "stranger@example.com", seller_id: seller.external_id }, format: :json
            end.not_to change { Follower.count }
          end.not_to have_enqueued_mail(FollowerMailer, :confirm_follower)

          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.parsed_body["success"]).to be(false)
        end
      end

      # The JSON shape serves the gumroad:follow bridge on custom HTML pages:
      # the trusted wrapper fetches this endpoint and relays the outcome into
      # the sandboxed page, where a redirect or an Inertia document would be
      # useless. The HTML behavior above must stay untouched — the legacy
      # third-party embed form still posts as a plain form.
      context "as JSON (custom HTML follow bridge)" do
        it "creates the follower with embed-form attribution and returns the confirmation message" do
          post :from_embed_form, params: { email: "follower@example.com", seller_id: seller.external_id }, format: :json

          expect(response).to be_successful
          expect(response.parsed_body).to eq("success" => true, "message" => "Check your inbox to confirm your follow request.")
          follower = Follower.last
          expect(follower.email).to eq("follower@example.com")
          expect(follower.user).to eq(seller)
          expect(follower.source).to eq(Follower::From::EMBED_FORM)
        end

        it "returns the validation message with 422 for an invalid email" do
          post :from_embed_form, params: { email: "exampleexample.com", seller_id: seller.external_id }, format: :json

          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["message"]).to include("Email invalid")
        end

        it "404s an unknown seller id" do
          post :from_embed_form, params: { email: "follower@example.com", seller_id: "does-not-exist" }, format: :json

          expect(response).to have_http_status(:not_found)
        end
      end

      # The action deliberately branches on request.format.json? instead of
      # respond_to: formats that never had an explicit branch (feeds, crawlers
      # sending odd Accept headers) must keep the old always-render/redirect
      # behavior rather than start raising UnknownFormat.
      it "keeps the legacy redirect behavior for formats other than HTML and JSON" do
        post :from_embed_form, params: { email: "exampleexample.com", seller_id: seller.external_id }, format: :xml

        expect(response).to redirect_to(seller.profile_url)
        expect(flash[:warning]).to include("Email invalid")
      end

      context "when the seller has not been reviewed yet" do
        # There is no CAPTCHA on the embed form for the visitor to solve — it is
        # HTML on someone else's website — which is exactly why this endpoint is
        # the one an abuser scripts. So it refuses the follow and offers the
        # seller's own subscribe page, which does render a challenge, instead of
        # accepting an unverified submission or dead-ending a real person.
        let(:unreviewed_seller) { create(:named_seller, username: "unreviewedseller", email: "unreviewed@example.com") }

        it "refuses the follow and offers the seller's subscribe page instead" do
          expect(unreviewed_seller.user_risk_state).to eq("not_reviewed")

          expect do
            post :from_embed_form, params: { email: "follower@example.com", seller_id: unreviewed_seller.external_id }
          end.to_not change { Follower.count }

          expect(inertia.component).to eq("Followers/FromEmbedForm")
          expect(inertia.props[:success]).to be(false)
          expect(inertia.props[:message]).to include(unreviewed_seller.name_or_username)
          expect(inertia.props[:subscribe_url]).to eq(custom_domain_subscribe_url(host: unreviewed_seller.subdomain_with_protocol))
        end

        it "sends no confirmation email" do
          expect do
            post :from_embed_form, params: { email: "follower@example.com", seller_id: unreviewed_seller.external_id }
          end.to_not have_enqueued_mail(FollowerMailer, :confirm_follower)
        end

        it "returns 422 with the destination in the message for the custom-page follow bridge" do
          post :from_embed_form, params: { email: "follower@example.com", seller_id: unreviewed_seller.external_id }, format: :json

          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["message"]).to include(unreviewed_seller.name_or_username)
          # The bridge relays this as plain text into a sandboxed page, so the URL
          # has to be in the sentence — there is no link element to render.
          expect(response.parsed_body["message"]).to include(custom_domain_subscribe_url(host: unreviewed_seller.subdomain_with_protocol))
        end

        # The refusal copy is built from name_or_username, which is never blank:
        # User#username falls back to the account's external id, so a seller with
        # no name and no claimed profile URL still names themselves by id.
        it "names the seller by id when they have no name and no claimed username" do
          nameless_seller = create(:user, name: nil, username: nil)

          post :from_embed_form, params: { email: "follower@example.com", seller_id: nameless_seller.external_id }, format: :json

          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.parsed_body["message"]).to start_with("Please subscribe from #{nameless_seller.external_id}'s subscribe page")
        end
      end
    end

    describe "GET cancel" do
      it "cancels the follow and renders Inertia page" do
        follower = create(:follower)
        expect { get :cancel, params: { id: follower.external_id } }.to change {
          follower.reload.deleted?
        }.from(false).to(true)
        expect(response).to be_successful
        expect(inertia.component).to eq("Followers/Cancel")
      end

      it "returns 404 when follower is invalid" do
        expect { get :cancel, params: { id: "invalid follower" } }.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
