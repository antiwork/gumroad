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
    let(:users_to_suspend) { create_list(:user, 2) }
    let(:user_ids_to_suspend) { users_to_suspend.map { |user| user.id.to_s } }
    let(:reason) { "Violating our terms of service" }
    let(:additional_notes) { nil }
    let(:scheduled_payout_params) { nil }
    let(:expected_scheduled_payout) { nil }

    before do
      params = { suspend_users: { identifiers: specified_ids, reason:, additional_notes: } }
      params[:scheduled_payout] = scheduled_payout_params if scheduled_payout_params
      put :update, params: params
    end

    context "when the specified users IDs are separated by newlines" do
      let(:specified_ids) { user_ids_to_suspend.join("\n") }

      it "enqueues a job to suspend the specified users" do
        expect(SuspendUsersWorker).to have_enqueued_sidekiq_job(admin_user.id, user_ids_to_suspend, reason, additional_notes, expected_scheduled_payout)
        expect(flash[:notice]).to eq "User suspension in progress!"
        expect(response).to redirect_to(admin_suspend_users_url)
      end
    end

    context "when the specified users IDs are separated by commas" do
      let(:specified_ids) { user_ids_to_suspend.join(", ") }

      it "enqueues a job to suspend the specified users" do
        expect(SuspendUsersWorker).to have_enqueued_sidekiq_job(admin_user.id, user_ids_to_suspend, reason, additional_notes, expected_scheduled_payout)
        expect(flash[:notice]).to eq "User suspension in progress!"
        expect(response).to redirect_to(admin_suspend_users_url)
      end
    end

    context "when external IDs are provided" do
      let(:external_ids_to_suspend) { users_to_suspend.map(&:external_id) }
      let(:specified_ids) { external_ids_to_suspend.join(", ") }

      it "enqueues a job to suspend the specified users" do
        expect(SuspendUsersWorker).to have_enqueued_sidekiq_job(admin_user.id, external_ids_to_suspend, reason, additional_notes, expected_scheduled_payout)
        expect(flash[:notice]).to eq "User suspension in progress!"
        expect(response).to redirect_to(admin_suspend_users_url)
      end
    end

    context "when additional notes are provided" do
      let(:additional_notes) { "Some additional notes" }
      let(:specified_ids) { user_ids_to_suspend.join(", ") }

      it "passes the additional notes as job's param" do
        expect(SuspendUsersWorker).to have_enqueued_sidekiq_job(admin_user.id, user_ids_to_suspend, reason, additional_notes, expected_scheduled_payout)
        expect(flash[:notice]).to eq "User suspension in progress!"
        expect(response).to redirect_to(admin_suspend_users_url)
      end
    end

    context "when a scheduled payout action is provided" do
      let(:specified_ids) { user_ids_to_suspend.join(", ") }
      let(:scheduled_payout_params) { { action: "payout", delay_days: "14" } }
      let(:expected_scheduled_payout) { { "action" => "payout", "delay_days" => "14" } }

      it "forwards the scheduled payout params to the worker" do
        expect(SuspendUsersWorker).to have_enqueued_sidekiq_job(admin_user.id, user_ids_to_suspend, reason, additional_notes, expected_scheduled_payout)
      end
    end

    context "when a hold action is provided without delay_days" do
      let(:specified_ids) { user_ids_to_suspend.join(", ") }
      let(:scheduled_payout_params) { { action: "hold", delay_days: "" } }
      let(:expected_scheduled_payout) { { "action" => "hold", "delay_days" => nil } }

      it "forwards the hold action and nil delay to the worker" do
        expect(SuspendUsersWorker).to have_enqueued_sidekiq_job(admin_user.id, user_ids_to_suspend, reason, additional_notes, expected_scheduled_payout)
      end
    end

    context "when scheduled payout action is blank" do
      let(:specified_ids) { user_ids_to_suspend.join(", ") }
      let(:scheduled_payout_params) { { action: "", delay_days: "14" } }

      it "does not forward scheduled payout params to the worker" do
        expect(SuspendUsersWorker).to have_enqueued_sidekiq_job(admin_user.id, user_ids_to_suspend, reason, additional_notes, nil)
      end
    end
  end
end
