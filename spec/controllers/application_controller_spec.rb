# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe ApplicationController do
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

  describe "#invalidate_session_if_necessary" do
    let!(:user) { create(:user, last_active_sessions_invalidated_at: 1.month.ago) }

    it "does not invalidate session if user is not logged in via devise" do
      index
      expect(response).to be_successful
    end

    it "does not invalidate session if user is not logged in via devise and logged_in_user is present" do
      allow(controller).to receive(:logged_in_user).and_return(user)
      index
      expect(response).to be_successful
    end

    it "invalidates session if user is logged in via devise and last_sign_in_at < last_active_sessions_invalidated_at" do
      sign_in user
      user.update!(last_active_sessions_invalidated_at: 1.day.from_now)
      index
      expect(response).to redirect_to(login_path)
    end
  end

  describe "includes CustomDomainRouteBuilder" do
    it { expect(ApplicationController.ancestors.include?(CustomDomainRouteBuilder)).to eq(true) }
  end

  describe "Event creation" do
    it "sets the referrer from params if its provided" do
      allow(controller).to receive(:params).and_return(referrer: "http://www.google.com")
      event = controller.create_service_charge_event(create(:service_charge))
      expect(event.referrer).to eq "http://www.google.com"
    end

    it "sets the referrer from params even if params is an array" do
      allow(controller).to receive(:params).and_return(referrer: ["https://gumroad.com", "https://www.google.com"])
      event = controller.create_service_charge_event(create(:service_charge))
      expect(event.referrer).to eq "https://www.google.com"
    end

    it "sets the referrer from the request if it is not provided in the params" do
      allow(controller).to receive(:params).and_return(referrer: nil)
      expect(request).to receive(:referrer).and_return("http://www.yahoo.com")
      event = controller.create_service_charge_event(create(:service_charge))
      expect(event.referrer).to eq "http://www.yahoo.com"
    end

    context "with admin signed" do
      let(:admin) { create(:admin_user) }
      let(:user) { create(:user) }

      before do
        sign_in admin
      end

      context "with admin becoming user" do
        before do
          controller.impersonate_user(user)
        end

        it "does not return an event" do
          stubbed_cookie
          event = controller.create_user_event("service_charge")
          expect(event).to be(nil)
        end
      end

      context "without admin becoming user" do
        it "returns an event" do
          stubbed_cookie
          event = controller.create_user_event("service_charge")
          expect(event).to_not be(nil)
        end
      end
    end

    it "saves the browser_plugins and friend actions in extra_features" do
      stubbed_cookie
      event = controller.create_user_event("service_charge")
      expect(event.extra_features[:browser_plugins]).to eq "emptypluginstring"
      expect(event.extra_features[:friend_actions]).to eq "fdkljafldkasjfkljasf"
      expect(event.extra_features[:browser]).to eq "Rails Testing"
      expect(event).to_not be(nil)
    end

    it "survives being called with nil" do
      event = controller.create_user_event(nil)
      expect(event).to be_nil
    end

    it "creates a permitted event when not logged in" do
      event = controller.create_user_event("first_purchase_on_profile_visit")
      expect(event).to be_present
    end

    it "does not create a non-permitted event when not logged in" do
      event = controller.create_user_event("unknown_event")
      expect(event).to be_nil
    end

    it "creates a non-permitted event when logged in" do
      allow(controller).to receive(:current_user).and_return(create(:user))
      event = controller.create_user_event("unknown_event")
      expect(event).to be_present
    end
  end

  describe "custom host redirection" do
    context "when the host is configured to redirect" do
      before do
        allow_any_instance_of(SubdomainRedirectorService).to receive(:redirects).and_return({ "live.gumroad.com" => "https://example.com" })
        @request.host = "live.gumroad.com"
        allow_any_instance_of(@request.class).to receive(:fullpath).and_return("/")

        index
      end

      it "redirects to redirect_url" do
        expect(response).to redirect_to("https://example.com")
      end
    end

    context "when the host+fullpath is configured to redirect" do
      before do
        allow_any_instance_of(SubdomainRedirectorService).to receive(:redirects).and_return({ "live.gumroad.com/123" => "https://example.com/123" })
        @request.host = "live.gumroad.com"
        allow_any_instance_of(@request.class).to receive(:fullpath).and_return("/123")

        index
      end

      it "redirects to redirect_url" do
        expect(response).to redirect_to("https://example.com/123")
      end
    end

    context "when the host is not configured to redirect" do
      it "renders successfully" do
        index

        expect(response).to be_successful
      end
    end
  end

  describe "#set_default_page_title" do
    controller(ApplicationController) do
      before_action :set_default_page_title

      def index
        head :ok
      end
    end

    it "is Local Gumroad for development" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
      get :index
      expect(controller.send(:page_title)).to eq("Local Gumroad")
    end

    it "is Staging Gumroad for staging" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("staging"))
      get :index
      expect(controller.send(:page_title)).to eq("Staging Gumroad")
    end

    it "is Gumroad for production" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      get :index
      expect(controller.send(:page_title)).to eq("Gumroad")
    end
  end

  describe "default_url_options" do
    it "adds protocol" do
      expect(subject.default_url_options({})[:protocol]).to match(/^http/)
      expect(subject.default_url_options[:protocol]).to match(/^http/)
    end
  end

  describe "is_bot?" do
    it "returns true for actual bots" do
      request.env["HTTP_USER_AGENT"] = BOT_MAP.keys.sample
      expect(subject.is_bot?).to be(true)
    end

    it "returns false for non bots" do
      request.env["HTTP_USER_AGENT"] = "Mozilla-Like-Thing"
      expect(subject.is_bot?).to be(false)
    end

    it "returns true for googlebotty stuff" do
      request.env["HTTP_USER_AGENT"] = "something new googlebot"
      expect(subject.is_bot?).to be(true)
    end
  end

  describe "is_mobile?" do
    it "returns true for mobile user agents" do
      @request.user_agent = "Some Mobile Browser"
      expect(subject.is_mobile?).to be(true)
    end

    it "returns false for desktop user agents" do
      @request.user_agent = "Some Desktop Browser"
      expect(subject.is_mobile?).to be(false)
    end
  end

  describe "authenticate_user!" do
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

    context "with html request" do
      describe "logged out" do
        it "redirects logged-out users to login when trying to access admin w proper next" do
          get :index

          expect(response).to redirect_to "/login?next=%2Fanonymous"
        end
      end
    end

    %i[js json].each do |request_format|
      context "with #{request_format} request" do
        describe "no authentication" do
          it "returns the correct json" do
            get :index, format: request_format

            expect(response).to have_http_status(:not_found)
            expect(response.parsed_body["success"]).to eq(false)
            expect(response.parsed_body["error"]).to eq("Not found")
          end
        end

        describe "with authentication" do
          before do
            sign_in create(:user)
          end

          it "returns the correct json" do
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

  describe "after_sign_in_path_for" do
    controller do
      def index
        redirect_to after_sign_in_path_for(logged_in_user)
      end
    end

    describe "has email" do
      before do
        @user = create(:user)
        sign_in @user
      end

      it "redirects the person home" do
        get :index
        expect(response).to redirect_to "/dashboard"
      end

      context "when next is present" do
        it "redirects to next" do
          get :index, params: { next: "/customers" }
          expect(response).to redirect_to "/customers"
        end

        it "strips out extra slashes and redirects to next as path" do
          get :index, params: { next: "////evil.org" }
          expect(response).to redirect_to "/evil.org"
        end

        it "redirects to relative path if next is a subdomain URL" do
          stub_const("ROOT_DOMAIN", "test.gumroad.com")
          get :index, params: { next: "https://username.test.gumroad.com/l/sample" }
          expect(response).to redirect_to "/l/sample"
        end
      end
    end
  end

  describe "after_sign_out_path_for" do
    before do
      @product = create(:product, unique_permalink: "wq")
      @user = create(:user, confirmed_at: 1.day.ago, username: "dude")
      sign_in @user
    end

    describe "on product page" do
      it "goes to appropriate page after logging out" do
        allow(controller.request).to receive(:referrer).and_return("/l/wq")
        expect(subject.send(:after_sign_out_path_for, @user)).to eq "/l/wq"
      end
    end

    describe "on user page" do
      it "goes to appropriate page after logging out" do
        allow(controller.request).to receive(:referrer).and_return("/dude")
        expect(subject.send(:after_sign_out_path_for, @user)).to eq "/dude"
      end
    end

    describe "not on product page" do
      it "goes to appropriate page after logging out" do
        allow(controller.request).to receive(:referrer).and_return("/about")
        expect(subject.send(:after_sign_out_path_for, @user)).to eq "/about"
      end
    end
  end

  describe "login_path_for" do
    before do
      @user = create(:user)
    end

    controller do
      def index
        @user = User.find(params[:id])
        redirect_to login_path_for(@user)
      end
    end

    describe "is_buyer" do
      before do
        @user = create(:user)
        create(:purchase, purchaser: @user)
      end

      it "redirects to library" do
        get :index, params: { id: @user.id }
        expect(response).to redirect_to "/library"
      end
    end

    describe "params[:next]" do
      it "redirects to next" do
        get :index, params: { id: @user.id, next: "/about" }
        expect(response).to redirect_to "/about"
      end
    end

    describe "has referrer" do
      it "redirects to referrer" do
        request.headers["HTTP_REFERER"] = "/about"
        get :index, params: { id: @user.id }
        expect(response).to redirect_to "/about"
      end

      context "when referrer is login path" do
        it "doesn't redirect to referrer" do
          request.headers["HTTP_REFERER"] = "/login"

          get :index, params: { id: @user.id }

          expect(response).to_not redirect_to "/login"
          expect(response).to redirect_to "/dashboard"
        end
      end
    end
  end

  describe "e404" do
    it "raises the 404 routing error on missing template" do
      expect do
        get :jobs, format: "zip"
      end.to raise_error(ActionController::UrlGenerationError)
    end

    it "raises the 404 routing error" do
      expect do
        subject.send(:e404)
      end.to raise_error(ActionController::RoutingError)
    end
  end

  describe "e404_page" do
    it "raises the 404 routing error" do
      expect do
        subject.send(:e404_page)
      end.to raise_error(ActionController::RoutingError)
    end
  end

  describe "e404_json" do
    controller do
      def index
        e404_json
      end
    end

    it "returns the correct hash" do
      get :index
      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["error"]).to eq("Not found")
    end
  end

  describe "#strip_timestamp_location" do
    it "strips the location name" do
      # https://www.unicode.org/cldr/cldr-aux/charts/28/verify/zones/en.html
      # The location name is useless for determining the timestamp for the purpose parsing it for
      expected_timestamp = "Wed Jun 23 2021 14:32:31 GMT 0700"
      expect(subject.send(:strip_timestamp_location, "Wed Jun 23 2021 14:32:31 GMT 0700")).to eq(expected_timestamp)
      expect(subject.send(:strip_timestamp_location, "Wed Jun 23 2021 14:32:31 GMT 0700 (BST)")).to eq(expected_timestamp)
      expect(subject.send(:strip_timestamp_location, "Wed Jun 23 2021 14:32:31 GMT 0700 (Pacific Daylight Time)")).to eq(expected_timestamp)
      expect(subject.send(:strip_timestamp_location, "Wed Jun 23 2021 14:32:31 GMT 0700 (Novosibirsk Standard Time)")).to eq(expected_timestamp)
      expect(subject.send(:strip_timestamp_location, "Wed Jun 23 2021 14:32:31 GMT 0700 (Moscow Standard Time (Volgograd))")).to eq(expected_timestamp)
    end

    it "returns nil when passing nil" do
      expect(subject.send(:strip_timestamp_location, nil)).to eq(nil)
    end
  end

  describe "#set_signup_referrer" do
    before do
      @request.env["HTTP_REFERER"] = "http://google.com"
    end

    it "uses referrer from request object" do
      get :index
      expect(session[:signup_referrer]).to eq("google.com")
    end

    it "uses referrer from _sref param" do
      get :index, params: { _sref: "bing.com" }
      expect(session[:signup_referrer]).to eq("bing.com")
    end

    it "preserves existing referrer" do
      get :index
      get :index, params: { _sref: "bing.com" }
      expect(session[:signup_referrer]).to eq("google.com")
    end

    it "ignores referrer if user is logged in" do
      user = create(:user)
      sign_in user

      get :index
      expect(session).to_not have_key(:signup_referrer)
    end
  end

  describe "#add_user_to_bugsnag" do
    controller do
      # We can't test `before_bugsnag_notify` in test mode, so we're using an action as a proxy
      def index
        # By default, Bugsnag reports the user's id as an IP address
        $bugsnag_event = OpenStruct.new(user: { id: "127.0.0.1" })

        add_user_to_bugsnag($bugsnag_event)
        render plain: ""
      end
    end

    it "does not add user details when not logged in" do
      get :index
      expect($bugsnag_event.user).to eq(id: "127.0.0.1")
    end


    it "adds user info when logged in" do
      user = create(:user, username: "joe", name: "Joe", email: "joe@example.com")

      expected_hash = {
        email: "joe@example.com",
        locale: user.locale,
        id: user.id,
        name: "Joe",
        username: "joe",
      }

      allow(controller).to receive(:current_user).and_return(user)
      get :index
      expect($bugsnag_event.user).to include(expected_hash)

      allow(controller).to receive(:current_user).and_return(nil)
      allow(controller).to receive(:current_resource_owner).and_return(user)
      get :index
      expect($bugsnag_event.user).to include(expected_hash)
    end
  end
end
