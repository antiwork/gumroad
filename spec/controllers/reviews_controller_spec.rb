# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe ReviewsController, type: :controller, inertia: true do
  let(:user) { create(:user) }

  describe "GET index" do
    before do
      Feature.activate(:reviews_page)
      sign_in(user)
    end

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { ProductReview }
    end

    it "renders the Inertia component with correct props" do
      expect(ReviewsPresenter).to receive(:new).with(user).and_call_original

      get :index

      expect(response).to be_successful
      expect(inertia.component).to eq("Reviews/Index")
      expect(inertia.props[:reviews]).to be_an(Array)
      expect(inertia.props[:purchases]).to be_an(Array)
      expect(inertia.props[:following_wishlists_enabled]).to be_in([true, false])
    end
  end
end
