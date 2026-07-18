# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe PagesController, type: :controller, inertia: true do
  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  it_behaves_like "authorize called for controller", PagePolicy do
    let(:record) { :page }
    let(:request_params) { { slug: "about" } }
    let!(:page) { create(:user_page, pageable: seller, slug: "about", title: "About") }
  end

  describe "GET index" do
    let!(:page) { create(:user_page, pageable: seller, slug: "about", title: "About") }

    it "lists the seller's pages with the profile entry pinned" do
      get :index

      expect(response).to be_successful
      expect(inertia.component).to eq("Pages/Index")
      expect(inertia.props[:pages].map { _1[:slug] }).to eq(["about"])
      expect(inertia.props[:profile][:username]).to eq(seller.username)
    end

    it "counts only live products' custom pages for the product-pages row" do
      # A live product with a custom page counts; a live product without one
      # and a deleted product with one don't.
      with_page = create(:product, user: seller)
      with_page.custom_html = "<h1>Landing</h1>"
      with_page.save!
      create(:product, user: seller)
      deleted = create(:product, user: seller, deleted_at: Time.current)
      deleted.custom_html = "<h1>Gone</h1>"
      deleted.save!

      get :index

      expect(inertia.props[:product_pages_count]).to eq(1)
    end

    it "does not include another seller's pages" do
      create(:user_page, slug: "other", title: "Other")

      get :index

      expect(inertia.props[:pages].map { _1[:slug] }).to eq(["about"])
    end
  end

  describe "POST create" do
    it "creates a page with a slug derived from the title" do
      post :create, params: { title: "My FAQ", content: "<p>Q & A</p>" }

      page = seller.pages.last
      expect(page.slug).to eq("my-faq")
      expect(page.title).to eq("My FAQ")
      expect(response).to redirect_to(edit_page_path("my-faq"))
    end

    it "numbers the slug on collision" do
      create(:user_page, pageable: seller, slug: "my-faq", title: "My FAQ")

      post :create, params: { title: "My FAQ", content: "<p>Second</p>" }

      expect(seller.pages.order(:id).last.slug).to eq("my-faq-2")
    end

    it "skips reserved slugs so a page never shadows a storefront route" do
      post :create, params: { title: "Posts", content: "<p>Shadow?</p>" }

      expect(seller.pages.last.slug).to eq("posts-2")
    end

    it "rejects a blank title" do
      post :create, params: { title: "", content: "<p>Hi</p>" }

      expect(seller.pages.count).to eq(0)
      expect(response).to redirect_to(new_page_path)
    end
  end

  describe "GET edit" do
    let!(:page) { create(:user_page, pageable: seller, slug: "about", title: "About", content: "<p>Hi</p>") }

    it "renders the editor with the page's props" do
      get :edit, params: { slug: "about" }

      expect(response).to be_successful
      expect(inertia.component).to eq("Pages/Edit")
      expect(inertia.props[:page][:slug]).to eq("about")
      expect(inertia.props[:is_profile]).to eq(false)
    end

    it "renders the profile default-template view for the profile slug" do
      get :edit, params: { slug: "profile" }

      expect(response).to be_successful
      expect(inertia.props[:is_profile]).to eq(true)
    end

    it "redirects to the list for an unknown slug" do
      get :edit, params: { slug: "nope" }

      expect(response).to redirect_to(pages_path)
    end
  end

  describe "PATCH update" do
    let!(:page) { create(:user_page, pageable: seller, slug: "about", title: "About", content: "<p>Old</p>") }

    it "updates title and content" do
      patch :update, params: { slug: "about", title: "About me", content: "<p>New</p>" }

      expect(page.reload.title).to eq("About me")
      expect(page.content).to eq("<p>New</p>")
    end

    it "refuses to overwrite a custom HTML page from the editor" do
      page.update!(custom_html: "<h1>Agent-built</h1>")

      patch :update, params: { slug: "about", title: "About me", content: "<p>Manual edit</p>" }

      expect(page.reload.content).to eq("<p>Old</p>")
    end

    it "cannot update another seller's page" do
      other = create(:user_page, slug: "mine", title: "Not yours")

      patch :update, params: { slug: "mine", title: "Hijack", content: "" }

      expect(other.reload.title).to eq("Not yours")
      expect(response).to redirect_to(pages_path)
    end

    it "never writes over the profile entry" do
      patch :update, params: { slug: "profile", title: "Nope", content: "" }

      expect(response).to redirect_to(pages_path)
    end

    it "removes the profile's custom HTML takeover, restoring the default template" do
      seller.custom_html = "<h1>Takeover</h1>"
      seller.save!

      patch :update, params: { slug: "profile", remove_custom_html: true }

      expect(seller.reload.custom_html).to be_nil
      expect(response).to redirect_to(edit_page_path("profile"))
    end
  end

  describe "DELETE destroy" do
    let!(:page) { create(:user_page, pageable: seller, slug: "about", title: "About") }

    it "deletes the page" do
      expect do
        delete :destroy, params: { slug: "about" }
      end.to change { seller.pages.count }.by(-1)
    end

    it "never deletes the profile entry" do
      delete :destroy, params: { slug: "profile" }

      expect(response).to redirect_to(pages_path)
      expect(seller.pages.count).to eq(1)
    end
  end

  describe "GET preview" do
    let!(:page) { create(:user_page, pageable: seller, slug: "about", title: "About", custom_html: "<h1>Agent-built</h1><script>window.ok = true;</script>") }

    it "renders the page's custom HTML same-origin with the strict CSP" do
      get :preview, params: { slug: "about" }

      expect(response).to be_successful
      expect(response.body).to include("Agent-built")
      csp = response.headers["Content-Security-Policy"]
      expect(csp).to include("sandbox allow-scripts")
      expect(csp).not_to include("allow-same-origin")
      expect(csp).to include("default-src 'none'")
    end

    it "renders the profile's custom HTML takeover for the profile slug" do
      seller.custom_html = "<h1>Home takeover</h1>"
      seller.save!

      get :preview, params: { slug: "profile" }

      expect(response).to be_successful
      expect(response.body).to include("Home takeover")
    end

    it "renders the styled public document for a rich text page" do
      page.update!(custom_html: nil, content: "<p>Rich text</p>")

      get :preview, params: { slug: "about" }

      expect(response).to be_successful
      expect(response.body).to include("<h1 class=\"page-title\">About</h1>")
      expect(response.body).to include("<p>Rich text</p>")
    end

    it "404s for the profile slug without a custom HTML takeover (the editor frames the live storefront instead)" do
      seller.custom_html = nil
      seller.save!

      get :preview, params: { slug: "profile" }

      expect(response).to have_http_status(:not_found)
    end
  end
end
