# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"
require "shared_examples/authorize_called"
require "shared_examples/sellers_base_controller_concern"

describe EmailsController, inertia: true do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:user) }

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Installment }
    end

    it "redirects to the published tab" do
      get :index

      expect(response).to redirect_to("/emails/published")
    end

    it "redirects to the scheduled tab if there are scheduled installments" do
      installment = create(:installment, seller:, ready_to_publish: true)
      create(:installment_rule, installment:, to_be_published_at: 1.day.from_now)

      get :index

      expect(response).to redirect_to("/emails/scheduled")
    end
  end

  describe "GET published" do
    it_behaves_like "authorize called for action", :get, :published do
      let(:record) { Installment }
      let(:policy_method) { :index? }
    end

    it "renders the Emails/Published component with correct props" do
      installment = create(:installment, seller:, published_at: 1.day.ago)

      get :published

      expect(response).to have_http_status(:ok)
      expect_inertia.to render_component("Emails/Published")
      expect_inertia.to include_props(
        installments: [hash_including(external_id: installment.external_id, name: installment.displayed_name)],
        pagination: hash_including(:count, :next),
        has_posts: true
      )
    end
  end

  describe "GET scheduled" do
    it_behaves_like "authorize called for action", :get, :scheduled do
      let(:record) { Installment }
      let(:policy_method) { :index? }
    end

    it "renders the Emails/Scheduled component with correct props" do
      installment = create(:installment, seller:, ready_to_publish: true)
      create(:installment_rule, installment:, to_be_published_at: 1.day.from_now)

      get :scheduled

      expect(response).to have_http_status(:ok)
      expect_inertia.to render_component("Emails/Scheduled")
      expect_inertia.to include_props(
        installments: [hash_including(external_id: installment.external_id, name: installment.displayed_name)],
        pagination: hash_including(:count, :next),
        has_posts: true
      )
    end
  end

  describe "GET drafts" do
    it_behaves_like "authorize called for action", :get, :drafts do
      let(:record) { Installment }
      let(:policy_method) { :index? }
    end

    it "renders the Emails/Drafts component with correct props" do
      installment = create(:installment, seller:)

      get :drafts

      expect(response).to have_http_status(:ok)
      expect_inertia.to render_component("Emails/Drafts")
      expect_inertia.to include_props(
        installments: [hash_including(external_id: installment.external_id, name: installment.displayed_name)],
        pagination: hash_including(:count, :next),
        has_posts: true
      )
    end
  end

  describe "DELETE destroy" do
    let!(:installment) { create(:installment, seller:) }

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { installment }
      let(:request_params) { { id: installment.external_id } }
    end

    it "deletes the installment and redirects with flash message" do
      expect {
        delete :destroy, params: { id: installment.external_id }
      }.to change { Installment.alive.count }.by(-1)

      expect(response).to redirect_to(emails_path)
      expect(flash[:notice]).to eq("Email deleted!")
    end
  end
end
