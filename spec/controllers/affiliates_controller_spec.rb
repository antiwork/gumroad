# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"
require "inertia_rails/rspec"

describe AffiliatesController, type: :controller, inertia: true do
  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product, user: seller) }
  let(:affiliate_user) { create(:affiliate_user) }

  context "within seller area" do
    include_context "with user signed in as admin for seller"

    describe "GET index" do
      it_behaves_like "authentication required for action", :get, :index

      it_behaves_like "authorize called for action", :get, :index do
        let(:record) { DirectAffiliate }
      end

      it "renders the affiliates page" do
        create(:direct_affiliate, seller:, affiliate_user:)
        get :index

        expect(response).to be_successful
        expect(inertia.component).to eq("Affiliates/Index")
        expect(inertia.props[:affiliates]).to be_present
      end

      context "when creator does not have any affiliates" do
        it "redirects to the onboarding page" do
          get :index

          expect(response).to redirect_to(onboarding_affiliates_path)
        end
      end
    end

    describe "GET onboarding" do
      it "renders the onboarding page" do
        get :onboarding

        expect(response).to be_successful
        expect(inertia.component).to eq("Affiliates/Onboarding")
        expect(inertia.props[:products]).to be_an(Array)
      end
    end

    describe "GET new" do
      it_behaves_like "authorize called for action", :get, :new do
        let(:record) { DirectAffiliate }
        let(:policy_method) { :create? }
      end

      it "renders the new affiliate page" do
        get :new

        expect(response).to be_successful
        expect(inertia.component).to eq("Affiliates/New")
        expect(inertia.props[:products]).to be_an(Array)
        expect(inertia.props[:affiliates_disabled_reason]).to be_nil
      end
    end

    describe "GET edit" do
      let!(:affiliate) { create(:direct_affiliate, seller:, affiliate_user:) }

      it_behaves_like "authorize called for action", :get, :edit do
        let(:record) { affiliate }
        let(:policy_method) { :update? }
        let(:request_params) { { id: affiliate.external_id } }
      end

      it "renders the edit affiliate page" do
        get :edit, params: { id: affiliate.external_id }

        expect(response).to be_successful
        expect(inertia.component).to eq("Affiliates/Edit")
        expect(inertia.props[:affiliate][:id]).to eq(affiliate.external_id)
      end

      it "returns 404 for non-existent affiliate" do
        expect { get :edit, params: { id: "nonexistent" } }.to raise_error(ActionController::RoutingError)
      end
    end

    describe "POST create" do
      it_behaves_like "authorize called for action", :post, :create do
        let(:record) { DirectAffiliate }
        let(:params) { { affiliate: { email: affiliate_user.email, fee_percent: 10, apply_to_all_products: true, products: [{ id: product.external_id_numeric, enabled: true }] } } }
      end

      it "creates an affiliate and redirects" do
        post :create, params: { affiliate: { email: affiliate_user.email, fee_percent: 10, apply_to_all_products: true, products: [{ id: product.external_id_numeric, enabled: true }] } }

        expect(response).to redirect_to(affiliates_path)
        expect(flash[:notice]).to eq("Affiliate created successfully")
        expect(seller.direct_affiliates.count).to eq(1)
      end

      it "redirects back with errors on invalid params" do
        post :create, params: { affiliate: { email: "", fee_percent: 10, apply_to_all_products: true, products: [] } }

        expect(response).to redirect_to(new_affiliate_path)
      end
    end

    describe "PATCH update" do
      let!(:affiliate) { create(:direct_affiliate, seller:, affiliate_user:) }

      it_behaves_like "authorize called for action", :patch, :update do
        let(:record) { affiliate }
        let(:request_params) { { id: affiliate.external_id, affiliate: { email: affiliate_user.email, fee_percent: 15, apply_to_all_products: true, products: [{ id: product.external_id_numeric, enabled: true }] } } }
      end

      it "updates the affiliate and redirects" do
        patch :update, params: { id: affiliate.external_id, affiliate: { email: affiliate_user.email, fee_percent: 15, apply_to_all_products: true, products: [{ id: product.external_id_numeric, enabled: true }] } }

        expect(response).to redirect_to(affiliates_path)
        expect(flash[:notice]).to eq("Affiliate updated successfully")
      end

      it "returns 404 for non-existent affiliate" do
        expect { patch :update, params: { id: "nonexistent", affiliate: { email: affiliate_user.email } } }.to raise_error(ActionController::RoutingError)
      end
    end

    describe "DELETE destroy" do
      let!(:affiliate) { create(:direct_affiliate, seller:, affiliate_user:) }

      it_behaves_like "authorize called for action", :delete, :destroy do
        let(:record) { affiliate }
        let(:request_params) { { id: affiliate.external_id } }
      end

      it "deletes the affiliate and redirects" do
        delete :destroy, params: { id: affiliate.external_id }

        expect(response).to redirect_to(affiliates_path)
        expect(flash[:notice]).to eq("Affiliate deleted successfully")
        expect(affiliate.reload).to be_deleted
      end

      it "returns 404 for non-existent affiliate" do
        expect { delete :destroy, params: { id: "nonexistent" } }.to raise_error(ActionController::RoutingError)
      end
    end

    describe "GET export" do
      let!(:affiliate) { create(:direct_affiliate, seller:) }

      it_behaves_like "authentication required for action", :post, :export

      it_behaves_like "authorize called for action", :post, :export do
        let(:record) { DirectAffiliate }
        let(:policy_method) { :index? }
      end

      context "when export is synchronous" do
        it "sends data as CSV file" do
          get :export

          expect(response.header["Content-Type"]).to include "text/csv"
          expect(response.body.to_s).to include(affiliate.affiliate_user.email)
        end
      end

      context "when export is asynchronous" do
        before do
          stub_const("Exports::AffiliateExportService::SYNCHRONOUS_EXPORT_THRESHOLD", 0)
        end

        it "queues sidekiq job and redirects back" do
          get :export

          expect(Exports::AffiliateExportWorker).to have_enqueued_sidekiq_job(seller.id, seller.id)
          expect(flash[:warning]).to eq("You will receive an email with the data you've requested.")
          expect(response).to redirect_to(affiliates_path)
        end

        context "when admin is signed in and impersonates seller" do
          let(:admin_user) { create(:admin_user) }

          before do
            sign_in admin_user
            controller.impersonate_user(seller)
          end

          it "queues sidekiq job for the admin" do
            get :export

            expect(Exports::AffiliateExportWorker).to have_enqueued_sidekiq_job(seller.id, admin_user.id)
            expect(flash[:warning]).to eq("You will receive an email with the data you've requested.")
            expect(response).to redirect_to(affiliates_path)
          end
        end
      end
    end
  end

  context "within consumer area" do
    describe "GET subscribe_posts" do
      before do
        @direct_affiliate = create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 1500)
        @direct_affiliate_2 = create(:direct_affiliate, affiliate_user:, seller:,
                                                        affiliate_basis_points: 2500, deleted_at: Time.current)
      end

      it "successfully marks current user's all affiliate records for this creator as subscribed" do
        sign_in(affiliate_user)

        @direct_affiliate.update!(send_posts: false)
        @direct_affiliate_2.update!(send_posts: false)

        get :subscribe_posts, params: { id: @direct_affiliate.external_id }

        expect(@direct_affiliate.reload.send_posts).to be true
        expect(@direct_affiliate_2.reload.send_posts).to be true
      end
    end

    describe "GET unsubscribe_posts" do
      before do
        @direct_affiliate = create(:direct_affiliate, affiliate_user:, seller:,
                                                      affiliate_basis_points: 1500, deleted_at: Time.current)
        @direct_affiliate_2 = create(:direct_affiliate, affiliate_user:, seller:,
                                                        affiliate_basis_points: 2500)
      end

      it "successfully marks current user's all affiliate records for this creator as unsubscribed" do
        sign_in(affiliate_user)

        expect(@direct_affiliate.send_posts).to be true
        expect(@direct_affiliate_2.send_posts).to be true

        get :unsubscribe_posts, params: { id: @direct_affiliate_2.external_id }

        expect(@direct_affiliate.reload.send_posts).to be false
        expect(@direct_affiliate_2.reload.send_posts).to be false
      end
    end
  end
end
