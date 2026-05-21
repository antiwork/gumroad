# frozen_string_literal: true

require "spec_helper"

describe PagesController, type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:user) }

  around do |example|
    orig = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false
    example.run
    ActionController::Base.allow_forgery_protection = orig
  end

  before do
    allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
    Feature.activate(:pages)
    sign_in seller
  end

  def stub_ai_generator(html: "<section class=\"py-12\"><h1>Stubbed</h1></section>")
    allow(Ai::PageGeneratorService).to receive(:new).and_wrap_original do |_, **kwargs|
      service = double("Ai::PageGeneratorService")
      allow(service).to receive(:call) do
        version = kwargs[:page].page_versions.create!(html: html, prompt: kwargs[:prompt], parent: kwargs[:parent_version])
        Ai::PageGeneratorService::Result.new(html: html, version: version)
      end
      service
    end
  end

  describe "GET /pages" do
    it "renders the Pages/Index inertia page" do
      get pages_path, headers: { "X-Inertia" => "true" }
      expect(response).to have_http_status(:ok)
      props = JSON.parse(response.body)["props"]
      expect(props["pages"]).to eq([])
    end

    it "returns 404 when the pages feature flag is off" do
      Feature.deactivate(:pages)
      get pages_path
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /pages" do
    it "creates a page and redirects to edit" do
      expect do
        post pages_path, params: { page: { title: "Launch" } }
      end.to change(Page, :count).by(1)

      page = Page.last
      expect(page.title).to eq("Launch")
      expect(page.user).to eq(seller)
      expect(response).to redirect_to(edit_page_path(page.slug))
    end

    it "associates with a product when permalink given" do
      product = create(:product, user: seller)
      post pages_path, params: { page: { title: "Course landing", product_permalink: product.unique_permalink } }
      expect(Page.last.link).to eq(product)
    end
  end

  describe "POST /pages/:id/generate" do
    let(:page) { create(:page, user: seller) }

    before { stub_ai_generator }

    it "creates a page version and saves the html" do
      expect do
        post generate_page_path(page.slug), params: { prompt: "A bold page" }, headers: { "Accept" => "application/json" }
      end.to change(page.page_versions, :count).by(1)

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["success"]).to be(true)
      expect(json["html"]).to include("Stubbed")
      expect(page.reload.html_content).to include("Stubbed")
    end

    it "returns 422 on blank prompt" do
      post generate_page_path(page.slug), params: { prompt: "  " }, headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "POST /pages/:id/publish" do
    it "publishes the page" do
      page = create(:page, user: seller, html_content: "<div>hi</div>")
      post publish_page_path(page.slug), headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(page.reload.published).to be(true)
      expect(page.published_at).to be_present
    end
  end

  describe "GET /pages/templates" do
    it "returns the catalog of starter templates" do
      get templates_pages_path, headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      templates = JSON.parse(response.body)["templates"]
      expect(templates).to be_an(Array)
      expect(templates.size).to be >= 6
      template = templates.first
      expect(template.keys).to include("id", "name", "description", "icon")
      expect(template.keys).not_to include("prompt")
    end
  end

  describe "auto-fill prompt (Item 1)" do
    before { stub_ai_generator }

    it "creates a first version from the product context when product_permalink is supplied" do
      product = create(:product, user: seller, name: "My Course")
      expect do
        post pages_path, params: { page: { title: "Course landing", product_permalink: product.unique_permalink } }
      end.to change(Page, :count).by(1).and change(PageVersion, :count).by(1)

      version = PageVersion.last
      expect(version.prompt).to include("My Course")
    end

    it "uses an explicit initial_prompt when supplied" do
      post pages_path, params: { page: { title: "Hand-rolled", initial_prompt: "An emerald hero section with a single CTA" } }
      expect(PageVersion.last.prompt).to include("emerald hero")
    end
  end

  describe "template grid (Item 2)" do
    before { stub_ai_generator }

    it "seeds the first version with the chosen template's prompt" do
      template = Ai::PageTemplates::TEMPLATES.first
      post pages_path, params: { page: { title: "From template", template_id: template[:id] } }
      version = PageVersion.last
      expect(version.prompt).to eq(template[:prompt])
    end

    it "exposes the template list as an inertia prop on /pages/new" do
      get new_page_path, headers: { "X-Inertia" => "true" }
      props = JSON.parse(response.body)["props"]
      expect(props["templates"].map { |t| t["id"] }).to include("minimal-product", "sleek-dark", "neobrutalist")
    end
  end

  describe "profile page (Item 4)" do
    it "creates a profile page when is_profile=true" do
      post pages_path, params: { page: { title: "My profile", is_profile: "true" } }
      expect(Page.last.is_profile).to be(true)
    end

    it "refuses a second profile page for the same user" do
      create(:profile_page, user: seller)
      expect do
        post pages_path, params: { page: { title: "Another profile", is_profile: "true" } }
      end.not_to change(Page, :count)
      expect(response).to redirect_to(new_page_path)
    end
  end

  describe "content moderation (Item 5)" do
    let(:page) { create(:page, user: seller) }

    before { stub_ai_generator }

    it "rejects the generate call when moderation flags the prompt" do
      allow(ContentModeration::ModerateRecordService).to receive(:check).and_return(
        ContentModeration::ModerateRecordService::CheckResult.new(passed: false, reasons: ["hate speech"])
      )
      post generate_page_path(page.slug), params: { prompt: "anything" }, headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to include("moderation")
      expect(page.reload.html_content).to be_blank
    end

    it "lets the call through when moderation passes" do
      allow(ContentModeration::ModerateRecordService).to receive(:check).and_return(
        ContentModeration::ModerateRecordService::CheckResult.new(passed: true, reasons: [])
      )
      post generate_page_path(page.slug), params: { prompt: "anything" }, headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
    end
  end
end
