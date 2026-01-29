# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe HelpCenter::CategoriesController, inertia: true do
  render_views

  describe "GET show" do
    let(:category) { HelpCenter::Category.first }

    it "returns successful response with Inertia page data" do
      get :show, params: { slug: category.slug }
      expect(response).to be_successful
      expect(inertia.component).to eq("HelpCenter/Categories/Show")
      expect(inertia.props[:category]).to include(
        title: category.title,
        slug: category.slug
      )
      expect(inertia.props[:category][:articles]).to be_an(Array)
    end

    it "includes sidebar categories" do
      get :show, params: { slug: category.slug }
      expect(inertia.props[:sidebar_categories]).to be_an(Array)
      expect(inertia.props[:sidebar_categories].first).to include(:title, :slug, :url)
    end

    it "sets meta tags" do
      get :show, params: { slug: category.slug }
      expect(response.body).to include("#{category.title} - Gumroad Help Center</title>")
    end

    it "redirects to help center root for non-existent categories" do
      get :show, params: { slug: "non-existent-category" }
      expect(response).to redirect_to(help_center_root_path)
    end
  end
end
