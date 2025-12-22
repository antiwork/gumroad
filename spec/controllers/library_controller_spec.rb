# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe LibraryController, :vcr, type: :controller, inertia: true do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:user) { create(:user) }
  let(:policy_klass) { PurchasePolicy }

  before do
    sign_in user
  end

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Purchase }
    end

    describe "normal products" do
      let!(:visible_purchase) { create(:purchase, purchaser: user, link: create(:product, name: "Visible Product")) }

      it "renders Library/Index with Inertia" do
        get :index
        expect(response).to be_successful
        expect(inertia.component).to eq("Library/Index")
        expect(inertia.props[:results]).to be_an(Array)
        expect(inertia.props[:results].map { |r| r.dig(:product, :name) }).to include("Visible Product")
      end

      it "doesn't show refunded purchases" do
        refunded_purchase = create(:purchase, purchaser: user, link: create(:product, name: "Refunded Product"))
        refunded_purchase.update_column(:stripe_refunded, true)
        get :index
        expect(response).to be_successful
        product_names = inertia.props[:results].map { |r| r.dig(:product, :name) }
        expect(product_names).to include("Visible Product")
        expect(product_names).to_not include("Refunded Product")
      end

      it "doesn't show charged back purchases" do
        chargeback_purchase = create(:purchase, purchaser: user, link: create(:product, name: "Chargeback Product"))
        chargeback_purchase.update_column(:chargeback_date, Time.current)
        get :index
        expect(response).to be_successful
        product_names = inertia.props[:results].map { |r| r.dig(:product, :name) }
        expect(product_names).to include("Visible Product")
        expect(product_names).to_not include("Chargeback Product")
      end

      it "doesn't show gift sender purchases" do
        link = create(:product, name: "Product name")
        purchase = create(:purchase, purchaser: user, link:, is_gift_sender_purchase: true)
        create(:gift, gifter_email: "sahil@gumroad.com", giftee_email: "sahil2@gumroad.com", link_id: link.id, gifter_purchase_id: purchase.id)
        get :index
        expect(response).to be_successful
        product_names = inertia.props[:results].map { |r| r.dig(:product, :name) }
        expect(product_names).to_not include(link.name)
      end
    end

    describe "failed webhooks" do
      before do
        @purchase = create(:purchase, url_redirect: nil, webhook_failed: true, purchaser: user)
      end

      it "renders successfully" do
        get :index
        expect(response).to be_successful
        expect(inertia.component).to eq("Library/Index")
      end
    end

    context "when an unconfirmed user attempts to access the library" do
      shared_examples "sends confirmation instructions" do
        it "disallows access and sends confirmation instructions" do
          allow(controller).to receive(:current_user).and_return(user)
          expect(user).to receive(:send_confirmation_instructions)

          get :index

          expect(response).to redirect_to settings_main_path
          expect(flash[:warning]).to eq("Please check your email to confirm your address before you can see that.")
        end
      end

      before do
        user.update_attribute(:confirmed_at, nil)
      end

      context "when no confirmation instructions were sent to user" do
        before do
          user.update_attribute(:confirmation_sent_at, nil)
        end

        it_behaves_like "sends confirmation instructions"
      end

      context "when previous confirmation instructions were sent more than 24 hours ago" do
        before do
          user.update_attribute(:confirmation_sent_at, 25.hours.ago)
        end

        it_behaves_like "sends confirmation instructions"
      end

      context "when confirmation instructions were sent within the last 24 hours" do
        before do
          user.update_attribute(:confirmation_sent_at, 5.hours.ago)
        end

        it "doesn't send duplicate confirmation instructions" do
          allow(controller).to receive(:current_user).and_return(user)
          expect(user).not_to receive(:send_confirmation_instructions)

          get :index
        end
      end
    end

    describe "suspended (tos) user" do
      before do
        @admin_user = create(:user)
        @product = create(:product, user:)
        user.flag_for_tos_violation(author_id: @admin_user.id, product_id: @product.id)
        user.suspend_for_tos_violation(author_id: @admin_user.id)
        # NOTE: The invalidate_active_sessions! callback from suspending the user, interferes
        # with the login mechanism, this is a hack get the `sign_in user` method work correctly
        request.env["warden"].session["last_sign_in_at"] = DateTime.current.to_i
      end

      it "allows access" do
        get :index
        expect(response).to be_successful
      end
    end

    describe "suspended (fraud) user" do
      before do
        @admin_user = create(:user)
        user.flag_for_fraud(author_id: @admin_user.id)
        user.suspend_for_fraud(author_id: @admin_user.id)
      end

      it "disallows access and redirects to the login page" do
        get :index
        expect(response).to redirect_to "/login"
      end
    end
  end

  describe "PATCH archive" do
    let!(:purchase) { create(:purchase, purchaser: user) }

    it_behaves_like "authorize called for action", :patch, :archive do
      let(:record) { purchase }
      let(:request_params) { { id: purchase.external_id } }
    end

    it "archives the purchase" do
      expect do
        patch :archive, params: { id: purchase.external_id }

        expect(response).to redirect_to(library_path)
        expect(flash[:notice]).to eq("Product archived!")
      end.to change { purchase.reload.is_archived }.from(false).to(true)
    end
  end

  describe "PATCH unarchive" do
    let!(:purchase) { create(:purchase, purchaser: user, is_archived: true) }

    it_behaves_like "authorize called for action", :patch, :unarchive do
      let(:record) { purchase }
      let(:request_params) { { id: purchase.external_id } }
    end

    it "unarchives the purchase" do
      expect do
        patch :unarchive, params: { id: purchase.external_id }

        expect(response).to redirect_to(library_path)
        expect(flash[:notice]).to eq("Product unarchived!")
      end.to change { purchase.reload.is_archived }.from(true).to(false)
    end
  end

  describe "PATCH delete" do
    let!(:purchase) { create(:purchase, purchaser: user) }

    it_behaves_like "authorize called for action", :patch, :delete do
      let(:record) { purchase }
      let(:request_params) { { id: purchase.external_id } }
    end

    it "deletes the purchase" do
      expect do
        patch :delete, params: { id: purchase.external_id }

        expect(response).to redirect_to(library_path)
        expect(flash[:notice]).to eq("Product deleted!")
      end.to change { purchase.reload.is_deleted_by_buyer }.from(false).to(true)
    end
  end
end
