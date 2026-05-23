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

  def drain_page_jobs
    Pages::GeneratePageVersionJob.drain
  end

  describe "GET /pages" do
    it "returns 400 when neither product_id nor is_profile is given" do
      get pages_path, headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:bad_request)
    end

    it "returns the existing page for a product" do
      product = create(:product, user: seller)
      page = create(:page, user: seller, link: product, is_profile: false, title: "Course landing")
      get pages_path, params: { product_id: product.unique_permalink }, headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["pages"].map { |p| p["slug"] }).to eq([page.slug])
    end

    it "returns an empty array when the product has no page yet" do
      product = create(:product, user: seller)
      get pages_path, params: { product_id: product.unique_permalink }, headers: { "Accept" => "application/json" }
      expect(JSON.parse(response.body)["pages"]).to eq([])
    end

    it "returns the profile page when is_profile=true" do
      page = create(:page, user: seller, is_profile: true, title: "About me")
      get pages_path, params: { is_profile: "true" }, headers: { "Accept" => "application/json" }
      expect(JSON.parse(response.body)["pages"].map { |p| p["slug"] }).to eq([page.slug])
    end

    it "returns 404 when the pages feature flag is off" do
      Feature.deactivate(:pages)
      get pages_path, params: { is_profile: "true" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /pages" do
    it "fails when neither product nor profile is given (must have owner)" do
      expect do
        post pages_path, params: { page: { title: "Launch" } }
      end.not_to change(Page, :count)
      expect(response).to have_http_status(:found) # redirect_back fallback
    end

    it "creates a profile page when is_profile=true" do
      expect do
        post pages_path, params: { page: { title: "About me", is_profile: "true" } }
      end.to change(Page, :count).by(1)
      expect(Page.last.is_profile).to be(true)
      expect(response).to redirect_to(edit_page_path(Page.last.slug))
    end

    it "associates with a product when permalink given" do
      product = create(:product, user: seller)
      post pages_path, params: { page: { title: "Course landing", product_permalink: product.unique_permalink } }
      expect(Page.last.link).to eq(product)
      expect(response).to redirect_to(edit_page_path(Page.last.slug))
    end

    it "returns JSON edit_url when Accept: application/json" do
      product = create(:product, user: seller)
      post pages_path,
           params: { page: { product_permalink: product.unique_permalink } }.to_json,
           headers: { "Accept" => "application/json", "Content-Type" => "application/json" }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["edit_url"]).to eq(edit_page_path(Page.last.slug))
    end

    it "defaults title to the product name when title is omitted" do
      product = create(:product, user: seller, name: "My Course")
      post pages_path,
           params: { page: { product_permalink: product.unique_permalink } }.to_json,
           headers: { "Accept" => "application/json", "Content-Type" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(Page.last.title).to eq("My Course")
    end

    it "creates a profile page with a server-derived default title when none is supplied" do
      # The Customize-page button on the profile editor posts is_profile=true
      # with no title. The server must derive a default rather than 422.
      post pages_path,
           params: { page: { is_profile: "true" } }.to_json,
           headers: { "Accept" => "application/json", "Content-Type" => "application/json" }
      expect(response).to have_http_status(:ok)
      page = Page.last
      expect(page.is_profile).to be(true)
      expect(page.title).to be_present
    end

    it "creates a product page with a server-derived default title when title is an empty string" do
      product = create(:product, user: seller, name: "Inkwell")
      post pages_path,
           params: { page: { title: "", product_permalink: product.unique_permalink } }.to_json,
           headers: { "Accept" => "application/json", "Content-Type" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(Page.last.title).to eq("Inkwell")
    end

    context "when the v1 snapshot raises (defect 4)" do
      it "rolls back the Page insert so no orphan row is left behind" do
        allow(Ai::InitialPageSnapshot).to receive(:create_for!).and_raise(StandardError, "boom")
        expect do
          post pages_path,
               params: { page: { is_profile: "true" } }.to_json,
               headers: { "Accept" => "application/json", "Content-Type" => "application/json" }
        end.not_to change(Page, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["success"]).to be(false)
      end

      it "rolls back any placeholder page_version rows the snapshot inserted before raising" do
        # Simulate the realistic failure mode: create_for! inserts a placeholder
        # page_version (its first DB write) and then raises before updating the
        # page. Without the transaction, both the Page and the orphan version
        # row survive; with it, neither does.
        allow(Ai::InitialPageSnapshot).to receive(:create_for!).and_wrap_original do |_orig, page|
          page.page_versions.create!(html: "<div>placeholder</div>", prompt: "seed")
          raise StandardError, "snapshot crashed after writing placeholder"
        end

        expect do
          post pages_path,
               params: { page: { is_profile: "true" } }.to_json,
               headers: { "Accept" => "application/json", "Content-Type" => "application/json" }
        end.to not_change(Page, :count).and not_change(PageVersion, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  describe "POST /pages/:id/generate" do
    let(:page) { create(:page, user: seller) }

    before { stub_ai_generator }

    it "enqueues a generation job and applies the version when drained" do
      expect do
        post generate_page_path(page.slug), params: { prompt: "A bold page" }, headers: { "Accept" => "application/json" }
      end.to change(Pages::GeneratePageVersionJob.jobs, :size).by(1)

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["queued"]).to be(true)

      expect { drain_page_jobs }.to change(page.page_versions, :count).by(1)
      expect(page.reload.html_content).to include("Stubbed")
    end

    it "returns 422 on blank prompt" do
      post generate_page_path(page.slug), params: { prompt: "  " }, headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "clears generating_since on a retry after a previously failed generation" do
      # Simulate the post-failure state: a stale generating_since from a job
      # that bailed without resetting (Sidekiq worker died, lock leaked, etc.)
      # and a leftover generation_error from the prior run. Retrying must end
      # with generating_since cleared once the new job drains.
      page.update_columns(generating_since: 10.minutes.ago, generation_error: "Generation failed - please try again.")

      post generate_page_path(page.slug), params: { prompt: "fresh attempt" }, headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      drain_page_jobs

      page.reload
      expect(page.generating_since).to be_nil
      expect(page.generation_error).to be_nil
    end

    it "clears generating_since when perform_async dedups so the spinner is not stuck" do
      page.update_column(:generating_since, 5.minutes.ago)
      # Simulate sidekiq-unique-jobs returning nil (existing identical job
      # still locked, or leaked lock). No new worker will run, so the
      # controller must reset generating_since itself.
      allow(Pages::GeneratePageVersionJob).to receive(:perform_async).and_return(nil)

      post generate_page_path(page.slug), params: { prompt: "anything" }, headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["queued"]).to be(false)
      expect(page.reload.generating_since).to be_nil
    end
  end

  describe "POST /pages/:id/publish" do
    it "publishes the latest version by default" do
      page = create(:page, user: seller, html_content: "<div>hi</div>")
      version = create(:page_version, page: page, html: "<section>v1</section>", prompt: "x")
      post publish_page_path(page.slug), headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      page.reload
      expect(page.published).to be(true)
      expect(page.published_version_id).to eq(version.id)
      expect(page.html_content).to include("v1")
    end

    it "publishes a specific version without clobbering the working draft" do
      page = create(:page, user: seller, html_content: "<div>current</div>")
      v1 = create(:page_version, page: page, html: "<section>old</section>", prompt: "x")
      _v2 = create(:page_version, page: page, html: "<section>new</section>", prompt: "y")
      post publish_page_path(page.slug), params: { version_id: v1.id }, headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      page.reload
      expect(page.published_version_id).to eq(v1.id)
      # html_content is the editor's working draft — promoting an older version
      # must not displace it. Public visitors see published_version.html.
      expect(page.html_content).to eq("<div>current</div>")
    end

    it "returns 422 when version_id refers to a non-existent version" do
      page = create(:page, user: seller, html_content: "<div>x</div>")
      _v = create(:page_version, page: page, html: "<section>x</section>", prompt: "x")
      post publish_page_path(page.slug), params: { version_id: 999_999_999 },
                                         headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("Version not found")
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

    it "enqueues a first generation seeded from product context when product_permalink is supplied" do
      product = create(:product, user: seller, name: "My Course")
      expect do
        post pages_path, params: { page: { title: "Course landing", product_permalink: product.unique_permalink } }
      end.to change(Page, :count).by(1).and change(Pages::GeneratePageVersionJob.jobs, :size).by(1)

      job_prompt = Pages::GeneratePageVersionJob.jobs.last["args"][1]
      expect(job_prompt).to include("My Course")
    end

    it "uses an explicit initial_prompt when supplied (profile page owner)" do
      post pages_path, params: { page: { title: "Hand-rolled", is_profile: "true", initial_prompt: "An emerald hero section with a single CTA" } }
      expect(Pages::GeneratePageVersionJob.jobs.last["args"][1]).to include("emerald hero")
    end
  end

  describe "template grid (Item 2)" do
    before { stub_ai_generator }

    it "seeds the queued generation with the chosen template's prompt" do
      template = Ai::PageTemplates::TEMPLATES.first
      post pages_path, params: { page: { title: "From template", is_profile: "true", template_id: template[:id] } }
      expect(Pages::GeneratePageVersionJob.jobs.last["args"][1]).to eq(template[:prompt])
    end

    it "exposes the template list via the JSON templates endpoint" do
      get templates_pages_path, headers: { "Accept" => "application/json" }
      body = JSON.parse(response.body)
      expect(body["templates"].map { |t| t["id"] }).to include("album-not-store", "dive-bar", "tasteful-geocities")
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
      # Now redirect_back falls back to products_path because there is no
      # standalone /pages/new surface to bounce to anymore.
      expect(response).to have_http_status(:found)
    end
  end

  describe "content moderation (Item 5)" do
    let(:page) { create(:page, user: seller) }

    before { stub_ai_generator }

    it "rejects the generate call when moderation flags the prompt" do
      allow(ContentModeration::ModerateRecordService).to receive(:check).and_return(
        ContentModeration::ModerateRecordService::CheckResult.new(passed: false, reasons: ["hate speech"])
      )
      expect do
        post generate_page_path(page.slug), params: { prompt: "anything" }, headers: { "Accept" => "application/json" }
      end.not_to change(Pages::GeneratePageVersionJob.jobs, :size)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to include("isn't allowed")
      expect(page.reload.html_content).to be_blank
    end

    it "lets the call through when moderation passes" do
      allow(ContentModeration::ModerateRecordService).to receive(:check).and_return(
        ContentModeration::ModerateRecordService::CheckResult.new(passed: true, reasons: [])
      )
      post generate_page_path(page.slug), params: { prompt: "anything" }, headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(Pages::GeneratePageVersionJob.jobs.size).to eq(1)
    end

    it "rejects the create call before persisting the page when initial_prompt is flagged" do
      allow(ContentModeration::ModerateRecordService).to receive(:check).and_return(
        ContentModeration::ModerateRecordService::CheckResult.new(passed: false, reasons: ["disallowed"])
      )
      expect do
        post pages_path,
             params: { page: { is_profile: "true", initial_prompt: "something nasty" } }.to_json,
             headers: { "Accept" => "application/json", "Content-Type" => "application/json" }
      end.to not_change(Page, :count).and not_change(Pages::GeneratePageVersionJob.jobs, :size)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to include("isn't allowed")
    end
  end

  describe "GET /pages/:id/latest_version" do
    let(:page) { create(:page, user: seller) }

    it "reports generating=true when no version exists yet" do
      page.update_column(:generating_since, Time.current)
      get latest_version_page_path(page.slug), headers: { "Accept" => "application/json" }
      expect(JSON.parse(response.body)).to include("generating" => true, "html_content" => nil)
    end

    it "reports the latest version once one exists" do
      version = create(:page_version, page: page, html: "<section>hello</section>", prompt: "go")
      page.update!(html_content: version.html, published_version: version, auto_publish: true)
      get latest_version_page_path(page.slug), headers: { "Accept" => "application/json" }
      body = JSON.parse(response.body)
      expect(body["html_content"]).to include("hello")
      expect(body["latest_version"]["id"]).to eq(version.id)
      expect(body["generating"]).to be(false)
    end
  end

  describe "Pages::GeneratePageVersionJob" do
    let(:page) { create(:page, user: seller) }

    before { stub_ai_generator }

    it "creates a version and auto-publishes when auto_publish is on" do
      Pages::GeneratePageVersionJob.new.perform(page.id, "make it cool", nil)
      page.reload
      expect(page.page_versions.count).to eq(1)
      expect(page.published_version_id).to eq(page.page_versions.first.id)
      expect(page.published).to be(true)
    end

    it "does not auto-publish when auto_publish is off" do
      page.update!(auto_publish: false)
      Pages::GeneratePageVersionJob.new.perform(page.id, "make it cool", nil)
      page.reload
      expect(page.page_versions.count).to eq(1)
      expect(page.published).to be(false)
      expect(page.published_version_id).to be_nil
    end
  end
end
