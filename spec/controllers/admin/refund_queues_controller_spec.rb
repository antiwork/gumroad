# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::RefundQueuesController, type: :controller, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  let(:user_1) { create(:user, created_at: 1.day.ago, updated_at: 1.day.ago) }
  let(:user_2) { create(:user, created_at: 2.days.ago, updated_at: 2.days.ago) }
  let(:user_3) { create(:user, created_at: 3.days.ago, updated_at: 3.days.ago) }
  let(:users) do
    User.where(id: [user_1.id, user_2.id, user_3.id]).order(updated_at: :desc, id: :desc)
  end

  before(:each) do
    sign_in admin_user
  end

  describe "GET show" do
    before do
      allow(User).to receive(:refund_queue).and_return(users)
    end

    it "renders the page" do
      get :show

      expect(response).to be_successful
      expect(inertia.component).to eq "Admin/RefundQueues/Show"

      props = inertia.props
      expect(props[:title]).to eq("Refund queue")
      expect(props[:users]).to match_array([
                                             hash_including(external_id: user_1.external_id),
                                             hash_including(external_id: user_2.external_id),
                                             hash_including(external_id: user_3.external_id)
                                           ])
    end

    it "renders the page with pagination" do
      get :show, params: { page: 2, per_page: 2 }

      expect(response).to be_successful
      expect(inertia.component).to eq "Admin/RefundQueues/Show"

      props = inertia.props
      expect(props[:pagination]).to be_present
      expect(props[:users]).to contain_exactly(hash_including(external_id: user_3.external_id))
    end
  end
end
