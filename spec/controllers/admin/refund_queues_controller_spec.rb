# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::RefundQueuesController, type: :controller, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  let(:users) { create_list(:user, 3) }

  before(:each) do
    sign_in admin_user
  end

  describe "GET show" do
    before do
      allow(User).to receive(:refund_queue).and_return(User.where(id: users.map(&:id)))
    end

    it "renders the page" do
      get :show

      expect(response).to be_successful
      expect(inertia.component).to eq "Admin/RefundQueues/Show"

      props = inertia.props
      expect(props[:title]).to eq("Refund queue")
      expect(props[:users]).to match_array([
                                             hash_including(id: users[0].id),
                                             hash_including(id: users[1].id),
                                             hash_including(id: users[2].id)
                                           ])
    end
  end
end
