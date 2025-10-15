# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::SuspendUsersController, type: :controller, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  before(:each) do
    sign_in admin_user
  end

  describe "GET show" do
    it "renders the page" do
      get :show

      expect(response).to be_successful
      expect(inertia.component).to eq "Admin/SuspendUsers/Show"

      expect(inertia.props[:title]).to eq("Mass-suspend users")
      expect(inertia.props[:suspend_reasons]).to eq([
                                                      "Violating our terms of service",
                                                      "Creating products that violate our ToS",
                                                      "Using Gumroad to commit fraud",
                                                      "Using Gumroad for posting spam or SEO manipulation",
                                                    ])
      expect(inertia.props[:authenticity_token]).to be_present
    end
  end

  describe "PUT update" do
    let(:user_ids_to_suspend) { create_list(:user, 2).map { |user| user.id.to_s } }
    let(:reason) { "Violating our terms of service" }
    let(:additional_notes) { nil }

    context "when the specified users IDs are separated by newlines" do
      let(:specified_ids) { user_ids_to_suspend.join("\n") }

      it "enqueues a job to suspend the specified users" do
        put :update, params: { suspend_users: { identifiers: specified_ids, reason: } }

        expect(SuspendUsersWorker).to have_enqueued_sidekiq_job(admin_user.id, user_ids_to_suspend, reason, additional_notes)
        expect(flash[:notice]).to eq "User suspension in progress!"
        expect(response).to redirect_to(admin_suspend_users_url)
      end
    end

    context "when the specified users IDs are separated by commas" do
      let(:specified_ids) { user_ids_to_suspend.join(", ") }

      it "enqueues a job to suspend the specified users" do
        put :update, params: { suspend_users: { identifiers: specified_ids, reason: } }

        expect(SuspendUsersWorker).to have_enqueued_sidekiq_job(admin_user.id, user_ids_to_suspend, reason, additional_notes)
        expect(flash[:notice]).to eq "User suspension in progress!"
        expect(response).to redirect_to(admin_suspend_users_url)
      end
    end

    context "when additional notes are provided" do
      it "passes the additional notes as job's param" do
        additional_notes = "Some additional notes"
        put :update, params: { suspend_users: { identifiers: user_ids_to_suspend.join(", "), reason:, additional_notes:  } }

        expect(SuspendUsersWorker).to have_enqueued_sidekiq_job(admin_user.id, user_ids_to_suspend, reason, additional_notes)
        expect(flash[:notice]).to eq "User suspension in progress!"
        expect(response).to redirect_to(admin_suspend_users_url)
      end
    end
  end
end
