# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe AffiliateRequestsController do
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
          expect(response).to render_template(:new)
          expect(assigns[:title]).to eq("Become an affiliate for #{creator.display_name}")
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
          expect(response).to render_template(:new)
          expect(assigns[:title]).to eq("Become an affiliate for #{creator.display_name}")
        end
      end

      context "with user signed in as admin for seller" do
        let(:seller) { create(:named_seller) }

        include_context "with user signed in as admin for seller"

        it "assigns the correct instance variables and renders template" do
          get :new, params: { username: creator.username }

          expect(response).to be_successful
          expect(response).to render_template(:new)

          expect(assigns[:title]).to eq("Become an affiliate for #{creator.display_name}")
          expect(assigns[:hide_layouts]).to be(true)

          profile_presenter = assigns[:profile_presenter]
          expect(profile_presenter.seller).to eq(creator)
          expect(profile_presenter.pundit_user).to eq(controller.pundit_user)
        end
      end
    end
  end

  describe "POST create" do
    let(:creator) { create(:named_user) }
    let!(:product) { create(:product, user: creator) }

    context "when the creator has not enabled affiliate requests" do
      it "responds with an error" do
        post :create, params: { username: creator.username }, format: :json

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body["success"]).to eq false
      end
    end

    context "when the creator has enabled affiliate requests" do
      let!(:enabled_self_service_affiliate_product) { create(:self_service_affiliate_product, enabled: true, seller: creator, product:) }

      context "when the request payload is invalid" do
        it "responds with an error" do
          post :create, params: { username: creator.username, affiliate_request: { name: "John Doe", email: "foobar", promotion_text: "hello" } }, format: :json

          expect(response.parsed_body["success"]).to eq false
          expect(response.parsed_body["error"]).to eq "Email is invalid"
        end
      end

      context "when the request payload is valid" do
        it "creates an affiliate request and notifies both the requester and the creator" do
          expect_any_instance_of(AffiliateRequest).to receive(:notify_requester_and_seller_of_submitted_request).and_call_original

          expect do
            post :create, params: { username: creator.username, affiliate_request: { name: "John Doe", email: "john@example.com", promotion_text: "hello" } }, format: :json
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

          it "responds with 'requestor_has_account: true'" do
            post :create, params: { username: creator.username, affiliate_request: { name: "John Doe", email: requester.email, promotion_text: "hello" } }, format: :json

            expect(response.parsed_body["success"]).to eq(true)
            expect(response.parsed_body["requester_has_existing_account"]).to eq(true)
          end
        end

        context "when the requester does not have an account" do
          it "responds with 'requestor_has_account: false'" do
            post :create, params: { username: creator.username, affiliate_request: { name: "John Doe", email: "john@example.com", promotion_text: "hello" } }, format: :json

            expect(response.parsed_body["success"]).to eq(true)
            expect(response.parsed_body["requester_has_existing_account"]).to eq(false)
          end
        end

        context "when the creator has auto-approval for affiliates enabled" do
          it "approves the affiliate automatically" do
            Feature.activate_user(:auto_approve_affiliates, creator)

            post :create, params: { username: creator.username, affiliate_request: { name: "John Doe", email: "john@example.com", promotion_text: "hello" } }, format: :json

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

        it "responds with an error" do
          patch :update, params: { id: affiliate_request.external_id, affiliate_request: { action: "approve" } }, format: :json

          expect(response.parsed_body["success"]).to eq false
        end
      end

      it "approves a request" do
        expect_any_instance_of(AffiliateRequest).to receive(:make_requester_an_affiliate!)

        expect do
          patch :update, params: { id: affiliate_request.external_id, affiliate_request: { action: "approve" } }, format: :json
        end.to change { affiliate_request.reload.approved? }.from(false).to(true)

        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["affiliate_request"]["state"]).to eq("approved")
        expect(response.parsed_body["requester_has_existing_account"]).to eq(false)
      end

      it "ignores a request" do
        expect do
          patch :update, params: { id: affiliate_request.external_id, affiliate_request: { action: "ignore" } }, format: :json
        end.to change { affiliate_request.reload.ignored? }.from(false).to(true)

        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["affiliate_request"]["state"]).to eq("ignored")
        expect(response.parsed_body["requester_has_existing_account"]).to eq(false)
      end

      it "ignores an approved request for an affiliate who doesn't have an account" do
        affiliate_request.approve!

        expect do
          patch :update, params: { id: affiliate_request.external_id, affiliate_request: { action: "ignore" } }, format: :json
        end.to change { affiliate_request.reload.ignored? }.from(false).to(true)

        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["affiliate_request"]["state"]).to eq("ignored")
        expect(response.parsed_body["requester_has_existing_account"]).to eq(false)
      end

      it "responds with an error while ignoring an already approved request for an affiliate who has an account" do
        # Ensure that the affiliate has an account
        create(:user, email: affiliate_request.email)

        affiliate_request.approve!

        expect do
          patch :update, params: { id: affiliate_request.external_id, affiliate_request: { action: "ignore" } }, format: :json
        end.to_not change { affiliate_request.reload.ignored? }

        expect(response.parsed_body["success"]).to eq false
        expect(response.parsed_body["error"]).to eq("John Doe's affiliate request has been already processed.")
      end

      it "responds with an error for an unknown action name" do
        patch :update, params: { id: affiliate_request.external_id, affiliate_request: { action: "delete" } }, format: :json

        expect(response.parsed_body["success"]).to eq false
        expect(response.parsed_body["error"]).to eq("delete is not a valid affiliate request action")
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
              post :approve_all, format: :json
            end.not_to change { approved_request.reload }
          end.not_to change { ignored_request.reload }
        end.not_to change { other_seller_request.reload }

        expect(response).to have_http_status :ok
        expect(response.parsed_body["success"]).to eq true

        pending_requests.each do |request|
          expect(request.reload).to be_approved
        end
      end

      it "returns an error if there is a problem updating a record" do
        allow_any_instance_of(AffiliateRequest).to receive(:approve!).and_raise(ActiveRecord::RecordInvalid)

        sign_in seller

        post :approve_all, format: :json

        expect(response).to have_http_status :ok
        expect(response.parsed_body["success"]).to eq false
      end

      context "when seller is signed in" do
        before { sign_out(seller) }

        it "returns 404" do
          post :approve_all, format: :json

          expect(response).to have_http_status(:not_found)
          expect(response.parsed_body["success"]).to eq false
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
