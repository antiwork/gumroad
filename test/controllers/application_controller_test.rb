# frozen_string_literal: true

require "test_helper"
require "shared_examples/authorize_called"

class ApplicationControllerTest < ActionController::TestCase
  self.described_class = ApplicationController
  tests ApplicationController



  context_ ApplicationController do
    controller do
      def index
        render plain: "spec"
      end
    end

    def index(p = {})
      get :index, params: p
    end

    def stubbed_cookie
      calculated_fingerprint = "3dfakl93klfdjsa09rn"
      allow(controller).to receive(:params).and_return(plugins: "emptypluginstring",
                                                       friend: "fdkljafldkasjfkljasf")
      allow(Digest::MD5).to receive(:hexdigest).and_return(calculated_fingerprint)
      cookies[:_gumroad_guid] = "fdakjl9fdoakjs9"
    end

  context_ "#invalidate_session_if_necessary" do
      let!(:user) { create(:user, last_active_sessions_invalidated_at: 1.month.ago) }

  test "does not invalidate session if user is not logged in via devise" do
        index
        expect(response).to be_successful
      end

  test "does not invalidate session if user is not logged in via devise and logged_in_user is present" do
        allow(controller).to receive(:logged_in_user).and_return(user)
        index
        expect(response).to be_successful
      end

  test "invalidates session if user is logged in via devise and last_sign_in_at < last_active_sessions_invalidated_at" do
        sign_in user
        user.update!(last_active_sessions_invalidated_at: 1.day.from_now)
        index
        expect(response).to redirect_to(login_path)
      end
    end

  context_ "includes CustomDomainRouteBuilder" do
      it { expect(ApplicationController.ancestors.include?(CustomDomainRouteBuilder)).to eq(true) }
    end

  context_ "Event creation" do
  test "sets the referrer from params if its provided" do
        allow(controller).to receive(:params).and_return(referrer: "http://www.google.com")
        event = controller.create_service_charge_event(create(:service_charge))
        expect(event.referrer).to eq "http://www.google.com"
      end

  test "sets the referrer from params even if params is an array" do
        allow(controller).to receive(:params).and_return(referrer: ["https://gumroad.com", "https://www.google.com"])
        event = controller.create_service_charge_event(create(:service_charge))
        expect(event.referrer).to eq "https://www.google.com"
      end

  test "sets the referrer from the request if it is not provided in the params" do
        allow(controller).to receive(:params).and_return(referrer: nil)
        expect(request).to receive(:referrer).and_return("http://www.yahoo.com")
        event = controller.create_service_charge_event(create(:service_charge))
        expect(event.referrer).to eq "http://www.yahoo.com"
      end

  context_ "with admin signed" do
        let(:admin) { create(:admin_user) }
        let(:user) { create(:user) }

        before do
          sign_in admin
        end

  context_ "with admin becoming user" do
          before do
            controller.impersonate_user(user)
          end

  test "does not return an event" do
            stubbed_cookie
            event = controller.create_user_event("service_charge")
            expect(event).to be(nil)
          end
        end

  context_ "without admin becoming user" do
  test "returns an event" do
            stubbed_cookie
            event = controller.create_user_event("service_charge")
            expect(event).not_to be(nil)
          end
        end
      end

  test "saves the browser_plugins and friend actions in extra_features" do
        stubbed_cookie
        event = controller.create_user_event("service_charge")
        expect(event.extra_features[:browser_plugins]).to eq "emptypluginstring"
        expect(event.extra_features[:friend_actions]).to eq "fdkljafldkasjfkljasf"
        expect(event.extra_features[:browser]).to eq "Rails Testing"
        expect(event).not_to be(nil)
      end

  test "survives being called with nil" do
        event = controller.create_user_event(nil)
        expect(event).to be_nil
      end

  test "creates a permitted event when not logged in" do
        event = controller.create_user_event("first_purchase_on_profile_visit")
        expect(event).to be_present
      end

  test "does not create a non-permitted event when not logged in" do
        event = controller.create_user_event("unknown_event")
        expect(event).to be_nil
      end

  test "creates a non-permitted event when logged in" do
        allow(controller).to receive(:current_user).and_return(create(:user))
        event = controller.create_user_event("unknown_event")
        expect(event).to be_present
      end
    end

  context_ "custom host redirection" do
  context_ "when the host is configured to redirect" do
        before do
          allow_any_instance_of(SubdomainRedirectorService).to receive(:redirects).and_return({ "live.gumroad.com" => "https://example.com" })
          @request.host = "live.gumroad.com"
          allow_any_instance_of(@request.class).to receive(:fullpath).and_return("/")

          index
        end

  test "redirects to redirect_url" do
          expect(response).to redirect_to("https://example.com")
        end
      end

  context_ "when the host+fullpath is configured to redirect" do
        before do
          allow_any_instance_of(SubdomainRedirectorService).to receive(:redirects).and_return({ "live.gumroad.com/123" => "https://example.com/123" })
          @request.host = "live.gumroad.com"
          allow_any_instance_of(@request.class).to receive(:fullpath).and_return("/123")

          index
        end

  test "redirects to redirect_url" do
          expect(response).to redirect_to("https://example.com/123")
        end
      end

  context_ "when the host is not configured to redirect" do
  test "renders successfully" do
          index

          expect(response).to be_successful
        end
      end
    end

  context_ "#set_default_page_title" do
      controller(ApplicationController) do
        before_action :set_default_page_title

        def index
          head :ok
        end
      end

  test "is Local Gumroad for development" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
        get :index
        expect(controller.send(:page_title)).to eq("Local Gumroad")
      end

  test "is Staging Gumroad for staging" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("staging"))
        get :index
        expect(controller.send(:page_title)).to eq("Staging Gumroad")
      end

  test "is Gumroad for production" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        get :index
        expect(controller.send(:page_title)).to eq("Gumroad")
      end
    end

  context_ "default_url_options" do
  test "adds protocol" do
        expect(subject.default_url_options({})[:protocol]).to match(/^http/)
        expect(subject.default_url_options[:protocol]).to match(/^http/)
      end
    end

  context_ "is_bot?" do
  test "returns true for actual bots" do
        request.env["HTTP_USER_AGENT"] = BOT_MAP.keys.sample
        expect(subject.is_bot?).to be(true)
      end

  test "returns false for non bots" do
        request.env["HTTP_USER_AGENT"] = "Mozilla-Like-Thing"
        expect(subject.is_bot?).to be(false)
      end

  test "returns true for googlebotty stuff" do
        request.env["HTTP_USER_AGENT"] = "something new googlebot"
        expect(subject.is_bot?).to be(true)
      end
    end

  context_ "is_mobile?" do
  test "returns true for mobile user agents" do
        @request.user_agent = "Some Mobile Browser"
        expect(subject.is_mobile?).to be(true)
      end

  test "returns false for desktop user agents" do
        @request.user_agent = "Some Desktop Browser"
        expect(subject.is_mobile?).to be(false)
      end
    end

  context_ "authenticate_user!" do
      controller do
        before_action :authenticate_user!
        skip_before_action :verify_authenticity_token

        def index
          respond_to do |format|
            format.json { render json: { success: true } }
            format.js { render json: { success: true } }
            format.html { head :ok }
          end
        end
      end

  context_ "with html request" do
  context_ "logged out" do
  test "redirects logged-out users to login when trying to access admin w proper next" do
            get :index

            expect(response).to redirect_to "/login?next=%2Fanonymous"
          end
        end
      end

      %i[js json].each do |request_format|
  context_ "with #{request_format} request" do
  context_ "no authentication" do
  test "returns the correct json" do
              get :index, format: request_format

              expect(response).to have_http_status(:not_found)
              expect(response.parsed_body["success"]).to eq(false)
              expect(response.parsed_body["error"]).to eq("Not found")
            end
          end

  context_ "with authentication" do
            before do
              sign_in create(:user)
            end

  test "returns the correct json" do
              get :index, as: request_format

              expect(response).to be_successful
              # response.parsed_body cannot be used here as for JS format the content type is
              # `text/javascript; charset=utf-8` and is parsed as String
              expect(JSON.parse(response.body)["success"]).to be(true)
            end
          end
        end
      end
    end

  context_ "after_sign_in_path_for" do
      controller do
        def index
          redirect_to after_sign_in_path_for(logged_in_user)
        end
      end

  context_ "has email" do
        before do
          @user = create(:user)
          sign_in @user
        end

  test "redirects the person home" do
          get :index
          expect(response).to redirect_to "/dashboard"
        end

  context_ "when next is present" do
  test "redirects to next" do
            get :index, params: { next: "/customers" }
            expect(response).to redirect_to "/customers"
          end

  test "strips out extra slashes and redirects to next as path" do
            get :index, params: { next: "////evil.org" }
            expect(response).to redirect_to "/evil.org"
          end

  test "redirects to relative path if next is a subdomain URL" do
            stub_const("ROOT_DOMAIN", "test.gumroad.com")
            get :index, params: { next: "https://username.test.gumroad.com/l/sample" }
            expect(response).to redirect_to "/l/sample"
          end
        end
      end
    end

  context_ "after_sign_out_path_for" do
      before do
        @product = create(:product, unique_permalink: "wq")
        @user = create(:user, confirmed_at: 1.day.ago, username: "dude")
        sign_in @user
      end

  context_ "on product page" do
  test "goes to appropriate page after logging out" do
          allow(controller.request).to receive(:referrer).and_return("/l/wq")
          expect(subject.send(:after_sign_out_path_for, @user)).to eq "/l/wq"
        end
      end

  context_ "on user page" do
  test "goes to appropriate page after logging out" do
          allow(controller.request).to receive(:referrer).and_return("/dude")
          expect(subject.send(:after_sign_out_path_for, @user)).to eq "/dude"
        end
      end

  context_ "not on product page" do
  test "goes to appropriate page after logging out" do
          allow(controller.request).to receive(:referrer).and_return("/about")
          expect(subject.send(:after_sign_out_path_for, @user)).to eq "/about"
        end
      end
    end

  context_ "login_path_for" do
      before do
        @user = create(:user)
      end

      controller do
        def index
          @user = User.find(params[:id])
          redirect_to login_path_for(@user)
        end
      end

  context_ "is_buyer" do
        before do
          @user = create(:user)
          create(:purchase, purchaser: @user)
        end

  test "redirects to library" do
          get :index, params: { id: @user.id }
          expect(response).to redirect_to "/library"
        end
      end

  context_ "params[:next]" do
  test "redirects to next" do
          get :index, params: { id: @user.id, next: "/about" }
          expect(response).to redirect_to "/about"
        end
      end

  context_ "has referrer" do
  test "redirects to referrer" do
          request.headers["HTTP_REFERER"] = "/about"
          get :index, params: { id: @user.id }
          expect(response).to redirect_to "/about"
        end

  context_ "when referrer is login path" do
  test "doesn't redirect to referrer" do
            request.headers["HTTP_REFERER"] = "/login"

            get :index, params: { id: @user.id }

            expect(response).not_to redirect_to "/login"
            expect(response).to redirect_to "/dashboard"
          end
        end
      end
    end

  context_ "e404" do
  test "raises the 404 routing error on missing template" do
        expect do
          get :jobs, format: "zip"
        end.to raise_error(ActionController::UrlGenerationError)
      end

  test "raises the 404 routing error" do
        expect do
          subject.send(:e404)
        end.to raise_error(ActionController::RoutingError)
      end
    end

  context_ "e404_page" do
  test "raises the 404 routing error" do
        expect do
          subject.send(:e404_page)
        end.to raise_error(ActionController::RoutingError)
      end
    end

  context_ "e404_json" do
      controller do
        def index
          e404_json
        end
      end

  test "returns the correct hash" do
        get :index
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error"]).to eq("Not found")
      end
    end

  context_ "#strip_timestamp_location" do
  test "strips the location name" do
        # https://www.unicode.org/cldr/cldr-aux/charts/28/verify/zones/en.html
        # The location name is useless for determining the timestamp for the purpose parsing it for
        expected_timestamp = "Wed Jun 23 2021 14:32:31 GMT 0700"
        expect(subject.send(:strip_timestamp_location, "Wed Jun 23 2021 14:32:31 GMT 0700")).to eq(expected_timestamp)
        expect(subject.send(:strip_timestamp_location, "Wed Jun 23 2021 14:32:31 GMT 0700 (BST)")).to eq(expected_timestamp)
        expect(subject.send(:strip_timestamp_location, "Wed Jun 23 2021 14:32:31 GMT 0700 (Pacific Daylight Time)")).to eq(expected_timestamp)
        expect(subject.send(:strip_timestamp_location, "Wed Jun 23 2021 14:32:31 GMT 0700 (Novosibirsk Standard Time)")).to eq(expected_timestamp)
        expect(subject.send(:strip_timestamp_location, "Wed Jun 23 2021 14:32:31 GMT 0700 (Moscow Standard Time (Volgograd))")).to eq(expected_timestamp)
      end

  test "returns nil when passing nil" do
        expect(subject.send(:strip_timestamp_location, nil)).to eq(nil)
      end
    end

  context_ "#set_signup_referrer" do
      before do
        @request.env["HTTP_REFERER"] = "http://google.com"
      end

  test "uses referrer from request object" do
        get :index
        expect(session[:signup_referrer]).to eq("google.com")
      end

  test "uses referrer from _sref param" do
        get :index, params: { _sref: "bing.com" }
        expect(session[:signup_referrer]).to eq("bing.com")
      end

  test "preserves existing referrer" do
        get :index
        get :index, params: { _sref: "bing.com" }
        expect(session[:signup_referrer]).to eq("google.com")
      end

  test "ignores referrer if user is logged in" do
        user = create(:user)
        sign_in user

        get :index
        expect(session).not_to have_key(:signup_referrer)
      end
    end
  end
end
