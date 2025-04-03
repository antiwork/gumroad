# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe ReviewsController do
  render_views

  let(:user) { create(:user) }

  describe "GET index" do
    before do
      Feature.activate(:reviews_page)
      sign_in(user)
    end

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { ProductReview }
    end

    it "initializes the presenter with the correct arguments and sets the title" do
      expect(ReviewsPresenter).to receive(:new).with(user).and_call_original
      get :index
      expect(response).to be_successful
      expect(response.body).to have_selector("title:contains('Reviews')", visible: false)
    end
  end
end
