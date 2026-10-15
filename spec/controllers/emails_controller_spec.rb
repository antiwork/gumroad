# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/sellers_base_controller_concern"
require "inertia_rails/rspec"

describe EmailsController, type: :controller, inertia: true do
  it_behaves_like "inherits from Sellers::BaseController"

  render_views

  let(:seller) { create(:user) }

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Installment }
    end

    it "redirects to the published tab" do
      get :index

      expect(response).to redirect_to(published_emails_path)
    end

    it "redirects to the scheduled tab if there are scheduled installments" do
      create(:scheduled_installment, seller:)

      get :index

      expect(response).to redirect_to(scheduled_emails_path)
    end
  end

  describe "GET published" do
    it_behaves_like "authorize called for action", :get, :published do
      let(:record) { Installment }
      let(:policy_method) { :index? }
    end

    it "renders the Inertia component with correct props" do
      create(:installment, seller:, published_at: 1.day.ago)

      get :published

      expect(response).to be_successful
      expect(inertia.component).to eq("Emails/Published")
      expect(inertia.props).to include(
        installments: be_an(Array),
        pagination: be_a(Hash),
        has_posts: be_in([true, false])
      )
    end
  end

  describe "GET scheduled" do
    it_behaves_like "authorize called for action", :get, :scheduled do
      let(:record) { Installment }
      let(:policy_method) { :index? }
    end

    it "renders the Inertia component with correct props" do
      create(:scheduled_installment, seller:)

      get :scheduled

      expect(response).to be_successful
      expect(inertia.component).to eq("Emails/Scheduled")
      expect(inertia.props).to include(
        installments: be_an(Array),
        pagination: be_a(Hash),
        has_posts: be_in([true, false])
      )
    end
  end

  describe "GET drafts" do
    it_behaves_like "authorize called for action", :get, :drafts do
      let(:record) { Installment }
      let(:policy_method) { :index? }
    end

    it "renders the Inertia component with correct props" do
      create(:installment, seller:)

      get :drafts

      expect(response).to be_successful
      expect(inertia.component).to eq("Emails/Drafts")
      expect(inertia.props).to include(
        installments: be_an(Array),
        pagination: be_a(Hash),
        has_posts: be_in([true, false])
      )
    end
  end

  describe "GET new" do
    it_behaves_like "authorize called for action", :get, :new do
      let(:record) { Installment }
    end

    it "renders the Inertia component with correct props" do
      get :new

      expect(response).to be_successful
      expect(inertia.component).to eq("Emails/New")
      expect(inertia.props).to have_key(:context)
    end

    it "includes copy_from installment when copy_from param is present" do
      installment = create(:installment, seller:)
      get :new, params: { copy_from: installment.external_id }

      expect(response).to be_successful
      expect(inertia.props).to have_key(:installment)
    end
  end

  describe "GET edit" do
    let(:installment) { create(:installment, seller:) }

    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { installment }
      let(:request_params) { { id: installment.external_id } }
    end

    it "renders the Inertia component with correct props" do
      get :edit, params: { id: installment.external_id }

      expect(response).to be_successful
      expect(inertia.component).to eq("Emails/Edit")
      expect(inertia.props).to have_key(:installment)
      expect(inertia.props).to have_key(:context)
    end

    context "when installment doesn't exist" do
      it "returns 404" do
        expect { get :edit, params: { id: "nonexistent" } }.to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { Installment }
      let(:request_params) { { installment: { subject: "Test Email" } } }
    end

    context "when save is successful" do
      let(:new_installment) { build(:installment, seller:) }

      before do
        allow_any_instance_of(SaveInstallmentService).to receive(:process).and_return(true)
        allow_any_instance_of(SaveInstallmentService).to receive(:installment).and_return(new_installment)
      end

      it "redirects to edit email path with success notice" do
        post :create, params: { installment: { subject: "Test Email" } }

        expect(response).to redirect_to(edit_email_path(new_installment.external_id))
        expect(flash[:notice]).to eq("Email created!")
      end

      it "redirects to edit path when save_and_preview_post is clicked" do
        installment = create(:installment, seller:)
        allow_any_instance_of(SaveInstallmentService).to receive(:installment).and_return(installment)

        post :create, params: { installment: { subject: "Test Email" }, save_action_name: "save_and_preview_post" }

        expect(response).to redirect_to(edit_email_path(installment.external_id, preview_post: true))
        expect(flash[:notice]).to eq("Preview link opened.")
      end
    end

    context "when save fails" do
      before do
        allow_any_instance_of(SaveInstallmentService).to receive(:process).and_return(false)
        allow_any_instance_of(SaveInstallmentService).to receive(:error).and_return("Something went wrong")
      end

      it "redirects to new email path with alert" do
        post :create, params: { installment: { subject: "Test Email" } }

        expect(response).to redirect_to(new_email_path)
        expect(flash[:alert]).to eq("Something went wrong")
      end
    end
  end

  describe "PATCH update" do
    let(:installment) { create(:installment, seller:) }

    it_behaves_like "authorize called for action", :patch, :update do
      let(:record) { installment }
      let(:request_params) { { id: installment.external_id, installment: { subject: "Updated Email" } } }
    end

    context "when save is successful" do
      before do
        allow_any_instance_of(SaveInstallmentService).to receive(:process).and_return(true)
        allow_any_instance_of(SaveInstallmentService).to receive(:installment).and_return(installment)
      end

      it "redirects to edit email path with success notice" do
        patch :update, params: { id: installment.external_id, installment: { subject: "Updated Email" } }

        expect(response).to redirect_to(edit_email_path(installment.external_id))
        expect(flash[:notice]).to eq("Changes saved!")
      end
    end

    context "when save fails" do
      before do
        allow_any_instance_of(SaveInstallmentService).to receive(:process).and_return(false)
        allow_any_instance_of(SaveInstallmentService).to receive(:error).and_return("Something went wrong")
      end

      it "redirects to edit email path with alert" do
        patch :update, params: { id: installment.external_id, installment: { subject: "Updated Email" } }

        expect(response).to redirect_to(edit_email_path(installment.external_id))
        expect(flash[:alert]).to eq("Something went wrong")
      end
    end
  end

  describe "DELETE destroy" do
    let!(:installment) { create(:installment, seller:) }

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { installment }
      let(:request_params) { { id: installment.external_id } }
    end

    it "destroys the installment" do
      expect do
        delete :destroy, params: { id: installment.external_id }
      end.to change(Installment.alive, :count).by(-1)
    end

    it "redirects to emails path with success notice" do
      delete :destroy, params: { id: installment.external_id }

      expect(response).to redirect_to(emails_path)
      expect(flash[:notice]).to eq("Email deleted!")
    end
  end
end
