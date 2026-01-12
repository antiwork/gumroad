# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"
require "shared_examples/authorize_called"

describe AffiliateRequestsController, inertia: true do
  describe "GET new" do
    context "when the creator doesn't exist" do
      it "renders 404 page" do
        expect do
          get :new, params: { username: "someone" }
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end

    context "when requested through the app domain" do
      let(:creator) { create(:named_user) }

      it "redirects to the affiliates page on subdomain" do
        get :new, params: { username: creator.username }

        expect(response).to redirect_to custom_domain_new_affiliate_request_url(host: creator.subdomain_with_protocol)
        expect(response).to have_http_status(:moved_permanently)
      end
    end

    context "when the creator has not enabled affiliate requests" do
      let(:creator) { create(:named_user) }
      let!(:product) { create(:product, user: creator) }

      before do
        @request.host = URI.parse(creator.subdomain_with_protocol).host
      end

      it "renders 404 page" do
        expect do
          get :new, params: { username: creator.username }
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end

    context "when the creator has enabled affiliate requests" do
      let(:creator) { create(:named_user) }
      let(:product) { create(:product, user: creator) }
      let!(:enabled_self_service_affiliate_product) { create(:self_service_affiliate_product, enabled: true, seller: creator, product:) }

      before do
        @request.host = URI.parse(creator.subdomain_with_protocol).host
      end

      context "when the requester is not signed in" do
        it "renders the affiliate request form" do
          get :new, params: { username: creator.username }

          expect(response).to have_http_status(:ok)
          expect(assigns[:title]).to eq("Become an affiliate for #{creator.display_name}")
          expect(inertia.component).to eq("AffiliateRequests/New")
          expect(inertia.props[:creator_profile]).to be_present
          expect(inertia.props[:success]).to eq(false)
          expect(inertia.props[:requester_has_existing_account]).to eq(false)
          expect(inertia.props[:email_param]).to be_nil
        end
      end

      context "when the requester is signed in" do
        let(:requester) { create(:named_user) }

        before(:each) do
          sign_in requester
        end

        it "renders the affiliate request form" do
          get :new, params: { username: creator.username }

          expect(response).to have_http_status(:ok)
          expect(assigns[:title]).to eq("Become an affiliate for #{creator.display_name}")
          expect(inertia.component).to eq("AffiliateRequests/New")
          expect(inertia.props[:creator_profile]).to be_present
          expect(inertia.props[:success]).to eq(false)
          expect(inertia.props[:requester_has_existing_account]).to eq(false)
          expect(inertia.props[:email_param]).to be_nil
        end
      end

      context "with user signed in as admin for seller" do
        let(:seller) { create(:named_seller) }

        include_context "with user signed in as admin for seller"

        it "renders the affiliate request form" do
          get :new, params: { username: creator.username }

          expect(response).to be_successful
          expect(assigns[:title]).to eq("Become an affiliate for #{creator.display_name}")
          expect(inertia.component).to eq("AffiliateRequests/New")
          expect(inertia.props[:creator_profile]).to be_present
          expect(inertia.props[:success]).to eq(false)
          expect(inertia.props[:requester_has_existing_account]).to eq(false)
          expect(inertia.props[:email_param]).to be_nil
        end
      end
    end
  end

  describe "POST create" do
    let(:creator) { create(:named_user) }
    let!(:product) { create(:product, user: creator) }

    context "when the creator has not enabled affiliate requests" do
      it "responds with 404" do
        expect do
          post :create, params: { username: creator.username }
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end

    context "when the creator has enabled affiliate requests" do
      let!(:enabled_self_service_affiliate_product) { create(:self_service_affiliate_product, enabled: true, seller: creator, product:) }

      context "when the request payload is invalid" do
        it "redirects with warning" do
          post :create, params: { username: creator.username, affiliate_request: { name: "John Doe", email: "foobar", promotion_text: "hello" } }

          expect(response).to redirect_to(custom_domain_new_affiliate_request_path)
          expect(flash[:alert]).to eq("Email is invalid")
        end
      end

      context "when the request payload is valid" do
        it "creates an affiliate request and notifies both the requester and the creator" do
          expect_any_instance_of(AffiliateRequest).to receive(:notify_requester_and_seller_of_submitted_request).and_call_original

          expect do
            post :create, params: { username: creator.username, affiliate_request: { name: "John Doe", email: "john@example.com", promotion_text: "hello" } }
          end.to change { AffiliateRequest.count }.by(1)

          affiliate_request = AffiliateRequest.last
          expect(affiliate_request.email).to eq("john@example.com")
          expect(affiliate_request.promotion_text).to eq("hello")
          expect(affiliate_request.locale).to eq("en")
          expect(affiliate_request.seller).to eq(creator)
          expect(affiliate_request).not_to be_approved
        end

        context "when the requester already has an account" do
          let(:requester) { create(:user) }

          it "redirects with requester_has_existing_account: true" do
            post :create, params: { username: creator.username, affiliate_request: { name: "John Doe", email: requester.email, promotion_text: "hello" } }

            expect(response).to redirect_to(custom_domain_new_affiliate_request_path(success: true, requester_has_existing_account: true, email: requester.email))
          end
        end

        context "when the requester does not have an account" do
          it "redirects with requester_has_existing_account: false" do
            post :create, params: { username: creator.username, affiliate_request: { name: "John Doe", email: "john@example.com", promotion_text: "hello" } }

            expect(response).to redirect_to(custom_domain_new_affiliate_request_path(success: true, requester_has_existing_account: false, email: "john@example.com"))
          end
        end

        context "when the creator has auto-approval for affiliates enabled" do
          it "approves the affiliate automatically" do
            Feature.activate_user(:auto_approve_affiliates, creator)

            post :create, params: { username: creator.username, affiliate_request: { name: "John Doe", email: "john@example.com", promotion_text: "hello" } }

            affiliate_request = AffiliateRequest.find_by(email: "john@example.com")
            expect(affiliate_request).to be_approved
          end
        end
      end
    end
  end

  context "with user signed in as admin for seller" do
    let(:seller) { create(:named_seller) }

    include_context "with user signed in as admin for seller"

    describe "PATCH update" do
      let(:affiliate_request) { create(:affiliate_request, seller:) }

      it_behaves_like "authorize called for action", :put, :update do
        let(:record) { affiliate_request }
        let(:request_params) { { id: affiliate_request.external_id } }
      end

      context "when creator is not signed in" do
        before { sign_out(seller) }

        it "redirects to login" do
          patch :update, params: { id: affiliate_request.external_id, affiliate_request: { action: "approve" } }

          expect(response.redirect_url).to start_with(login_url)
        end
      end

      it "approves a request" do
        expect_any_instance_of(AffiliateRequest).to receive(:make_requester_an_affiliate!)

        expect do
          patch :update, params: { id: affiliate_request.external_id, affiliate_request: { action: "approve" } }
        end.to change { affiliate_request.reload.approved? }.from(false).to(true)

        expect(response).to redirect_to(affiliates_path)
        expect(flash[:notice]).to eq("Approved John Doe's request!")
      end

      it "ignores a request" do
        expect do
          patch :update, params: { id: affiliate_request.external_id, affiliate_request: { action: "ignore" } }
        end.to change { affiliate_request.reload.ignored? }.from(false).to(true)

        expect(response).to redirect_to(affiliates_path)
        expect(flash[:notice]).to eq("Ignored John Doe's request!")
      end

      it "ignores an approved request for an affiliate who doesn't have an account" do
        affiliate_request.approve!

        expect do
          patch :update, params: { id: affiliate_request.external_id, affiliate_request: { action: "ignore" } }
        end.to change { affiliate_request.reload.ignored? }.from(false).to(true)

        expect(response).to redirect_to(affiliates_path)
        expect(flash[:notice]).to eq("Ignored John Doe's request!")
      end

      it "redirects with a warning while ignoring an already approved request for an affiliate who has an account" do
        # Ensure that the affiliate has an account
        create(:user, email: affiliate_request.email)

        affiliate_request.approve!

        expect do
          patch :update, params: { id: affiliate_request.external_id, affiliate_request: { action: "ignore" } }
        end.to_not change { affiliate_request.reload.ignored? }

        expect(response).to redirect_to(affiliates_path)
        expect(flash[:alert]).to eq("John Doe's affiliate request has been already processed.")
      end

      it "redirects with a warning for an unknown action name" do
        patch :update, params: { id: affiliate_request.external_id, affiliate_request: { action: "delete" } }

        expect(response).to redirect_to(affiliates_path)
        expect(flash[:alert]).to eq("delete is not a valid affiliate request action")
      end
    end

    describe "POST approve_all" do
      let!(:pending_requests) { create_list(:affiliate_request, 2, seller:) }

      it_behaves_like "authorize called for action", :post, :approve_all do
        let(:record) { AffiliateRequest }
      end

      it "approves all pending affiliate requests" do
        approved_request = create(:affiliate_request, seller:, state: "approved")
        ignored_request = create(:affiliate_request, seller:, state: "ignored")
        other_seller_request = create(:affiliate_request)

        expect do
          expect do
            expect do
              post :approve_all
            end.not_to change { approved_request.reload }
          end.not_to change { ignored_request.reload }
        end.not_to change { other_seller_request.reload }

        expect(response).to redirect_to(affiliates_path)
        expect(flash[:notice]).to eq("Approved all pending affiliate requests!")

        pending_requests.each do |request|
          expect(request.reload).to be_approved
        end
      end

      it "redirects with a warning if there is a problem updating a record" do
        allow_any_instance_of(AffiliateRequest).to receive(:approve!).and_raise(ActiveRecord::RecordInvalid)

        sign_in seller

        post :approve_all

        expect(response).to redirect_to(affiliates_path)
        expect(flash[:alert]).to eq("Failed to approve all requests")
      end

      context "when seller is not signed in" do
        before { sign_out(seller) }

        it "redirects to login" do
          post :approve_all

          expect(response.redirect_url).to start_with(login_url)
        end
      end
    end
  end

  describe "GET approve" do
    let(:affiliate_request) { create(:affiliate_request) }

    before do
      sign_in affiliate_request.seller
    end

    context "when the affiliate request is not attended yet" do
      it "approves the affiliate request" do
        expect do
          get :approve, params: { id: affiliate_request.external_id }
        end.to change { affiliate_request.reload.approved? }.from(false).to(true)

        expect(response).to have_http_status(:ok)
        expect(response).to render_template(:email_link_status)
        expect(assigns[:message]).to eq("Approved John Doe's affiliate request.")
      end
    end

    context "when the affiliate request is already attended" do
      before(:each) do
        affiliate_request.ignore!
      end

      it "does nothing" do
        expect do
          get :approve, params: { id: affiliate_request.external_id }
        end.to_not change { affiliate_request.reload }

        expect(response).to have_http_status(:ok)
        expect(response).to render_template(:email_link_status)
        expect(assigns[:message]).to eq("John Doe's affiliate request has been already processed.")
      end
    end
  end

  describe "GET ignore" do
    let(:affiliate_request) { create(:affiliate_request) }

    before do
      sign_in affiliate_request.seller
    end

    context "when the affiliate request is not attended yet" do
      it "ignores the affiliate request" do
        expect do
          get :ignore, params: { id: affiliate_request.external_id }
        end.to change { affiliate_request.reload.ignored? }.from(false).to(true)

        expect(response).to have_http_status(:ok)
        expect(response).to render_template(:email_link_status)
        expect(assigns[:message]).to eq("Ignored John Doe's affiliate request.")
      end
    end

    context "when the affiliate request is already approved and the affiliate has an account" do
      before(:each) do
        # Ensure that the affiliate has an account
        create(:user, email: affiliate_request.email)

        affiliate_request.approve!
      end

      it "does nothing" do
        expect do
          get :ignore, params: { id: affiliate_request.external_id }
        end.to_not change { affiliate_request.reload }

        expect(response).to have_http_status(:ok)
        expect(response).to render_template(:email_link_status)
        expect(assigns[:message]).to eq("John Doe's affiliate request has been already processed.")
      end
    end

    context "when the affiliate request is already approved and the affiliate doesn't have an account" do
      before(:each) do
        affiliate_request.approve!
      end

      it "ignores the affiliate request" do
        expect do
          get :ignore, params: { id: affiliate_request.external_id }
        end.to_not change { affiliate_request.reload }

        expect(response).to have_http_status(:ok)
        expect(response).to render_template(:email_link_status)
        expect(assigns[:message]).to eq("Ignored John Doe's affiliate request.")
      end
    end
  end
end
