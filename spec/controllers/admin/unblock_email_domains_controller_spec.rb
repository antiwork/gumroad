# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::UnblockEmailDomainsController, type: :controller, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:non_admin_user) { create(:user) }
  let(:admin_user) { create(:admin_user) }

  before do
    sign_in admin_user
  end

  describe "GET show" do
    it "renders the page to unsuspend users if admin" do
      get :show
      expect(response).to be_successful
      expect(inertia.component).to eq "Admin/UnblockEmailDomains/Show"
    end
  end

  describe "PUT update" do
    let(:email_domains_to_unblock) { %w[example.com example.org] }
    let(:identifiers) { email_domains_to_unblock.join("\n") }

    it "enqueues a job to unsuspend the specified email domains" do
      put :update, params: { email_domains: { identifiers: } }
      expect(UnblockObjectWorker.jobs.size).to eq(2)
      expect(response).to redirect_to(admin_unblock_email_domains_url)
      expect(flash[:notice]).to eq "Email domains unblocked successfully!"
    end

    it "unblocks email domain", :sidekiq_inline do
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email_domain], "example.com", nil)

      put :update, params: { email_domains: { identifiers: } }
      expect(BlockedObject.last.object_value).to eq("example.com")
      expect(BlockedObject.last.blocked_at).to be_nil
    end
  end
end
