# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::Users::ProductsController, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  let(:user) { create(:user) }
  let!(:product1) { create(:product, user:) }
  let!(:product2) { create(:product, user:) }

  before do
    sign_in admin_user
  end

  describe "GET index" do
    before do
      get :index, params: { user_external_id: user.external_id }
    end

    it "returns successful response with Inertia page data" do
      expect(response).to be_successful
      expect(inertia.component).to eq("Admin/Users/Products/Index")
      expect(inertia.props[:products]).to contain_exactly(hash_including(external_id: product1.external_id), hash_including(external_id: product2.external_id))
      expect(inertia.props[:pagination]).to eq({ pages: 1, page: 1 })
    end

    context "when user has deleted products" do
      let(:product2) { create(:product, user:, deleted_at: Time.current) }

      it "includes deleted products in list" do
        expect(inertia.props[:products]).to contain_exactly(hash_including(external_id: product1.external_id), hash_including(external_id: product2.external_id))
      end
    end

    context "when user has banned products" do
      let(:product2) { create(:product, user:, banned_at: Time.current) }

      it "includes banned products in list" do
        expect(inertia.props[:products]).to contain_exactly(hash_including(external_id: product1.external_id), hash_including(external_id: product2.external_id))
      end
    end
  end
end
