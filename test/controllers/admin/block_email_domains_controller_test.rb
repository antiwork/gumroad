# frozen_string_literal: true

require "test_helper"
require "shared_examples/admin_base_controller_concern"

class AdminBlockEmailDomainsControllerTest < ActionController::TestCase
  self.described_class = Admin::BlockEmailDomainsController
  tests Admin::BlockEmailDomainsController



  context_ Admin::BlockEmailDomainsController, type: :controller, inertia: true do
    render_views

    it_behaves_like "inherits from Admin::BaseController"

    let(:admin_user) { create(:admin_user) }

    before do
      sign_in admin_user
    end

  context_ "GET show" do
  test "renders the page to suspend users" do
        get :show

        expect(response).to be_successful
        expect(inertia.component).to eq "Admin/BlockEmailDomains/Show"
      end
    end

  context_ "PUT update" do
      let(:email_domains_to_block) { %w[example.com example.org] }

  context_ "when the specified users IDs are separated by newlines" do
        let(:identifiers) { email_domains_to_block.join("\n") }

  test "enqueues a job to suspend the specified users" do
          put :update, params: { email_domains: { identifiers: } }
          expect(BlockObjectWorker.jobs.size).to eq(2)
          expect(response).to redirect_to(admin_block_email_domains_url)
          expect(flash[:notice]).to eq "Email domains blocked successfully!"
        end

  test "does not pass expiry date to BlockObjectWorker" do
          array_of_args = email_domains_to_block.map { |email_domain| ["email_domain", email_domain, admin_user.id] }
          expect(BlockObjectWorker).to receive(:perform_bulk).with(array_of_args, batch_size: 1_000).and_call_original

          put :update, params: { email_domains: { identifiers: } }
        end
      end

  context_ "when the specified users IDs are separated by commas" do
        let(:identifiers) { email_domains_to_block.join(", ") }

  test "enqueues a job to suspend the specified users" do
          put :update, params: { email_domains: { identifiers: } }
          expect(BlockObjectWorker.jobs.size).to eq(2)
          expect(response).to redirect_to(admin_block_email_domains_url)
          expect(flash[:notice]).to eq "Email domains blocked successfully!"
        end

  test "does not pass expiry date to BlockObjectWorker" do
          array_of_args = email_domains_to_block.map { |email_domain| ["email_domain", email_domain, admin_user.id] }
          expect(BlockObjectWorker).to receive(:perform_bulk).with(array_of_args, batch_size: 1_000).and_call_original

          put :update, params: { email_domains: { identifiers: } }
        end
      end
    end
  end
end
