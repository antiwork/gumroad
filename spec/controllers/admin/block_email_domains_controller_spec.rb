# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::BlockEmailDomainsController, type: :controller, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }

  before do
    sign_in admin_user
  end

  describe "GET show" do
    it "renders the page to suspend users" do
      get :show

      expect(response).to be_successful
      expect(response.body).to include("data-page")
      expect(inertia.component).to eq "Admin/BlockEmailDomains/Show"
    end
  end

  describe "PUT update" do
    let(:email_domains_to_block) { %w[example.com example.org] }

    context "when the specified users IDs are separated by newlines" do
      let(:identifiers) { email_domains_to_block.join("\n") }

      it "enqueues a job to suspend the specified users" do
        put :update, params: { email_domains: { identifiers: } }
        expect(BlockObjectWorker.jobs.size).to eq(2)
        expect(response).to redirect_to(admin_block_email_domains_url)
      end

      it "does not pass expiry date to BlockObjectWorker" do
        array_of_args = email_domains_to_block.map { |email_domain| ["email_domain", email_domain, admin_user.id] }
        expect(BlockObjectWorker).to receive(:perform_bulk).with(array_of_args, batch_size: 1_000).and_call_original

        put :update, params: { email_domains: { identifiers: } }
      end
    end

    context "when the specified users IDs are separated by commas" do
      let(:identifiers) { email_domains_to_block.join(", ") }

      it "enqueues a job to suspend the specified users" do
        put :update, params: { email_domains: { identifiers: } }
        expect(BlockObjectWorker.jobs.size).to eq(2)
        expect(response).to redirect_to(admin_block_email_domains_url)
      end

      it "does not pass expiry date to BlockObjectWorker" do
        array_of_args = email_domains_to_block.map { |email_domain| ["email_domain", email_domain, admin_user.id] }
        expect(BlockObjectWorker).to receive(:perform_bulk).with(array_of_args, batch_size: 1_000).and_call_original

        put :update, params: { email_domains: { identifiers: } }
      end
    end
  end
end
