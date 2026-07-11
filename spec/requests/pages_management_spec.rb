# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe "Pages management", type: :request, inertia: true do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:named_seller) }

  before do
    sign_in seller
    host! DOMAIN
  end

  def inertia_props
    JSON.parse(response.body)["props"]
  end

  describe "GET /pages" do
    let!(:page) { create(:user_page, pageable: seller, slug: "about", title: "About") }

    it "lists the seller's pages with the profile entry" do
      get pages_path, headers: { "X-Inertia" => "true" }

      expect(response).to be_successful
      expect(inertia_props["pages"].map { _1["slug"] }).to eq(["about"])
      expect(inertia_props["profile"]["username"]).to eq(seller.username)
    end

    it "does not include another seller's pages" do
      create(:user_page, slug: "other", title: "Other")

      get pages_path, headers: { "X-Inertia" => "true" }

      expect(inertia_props["pages"].map { _1["slug"] }).to eq(["about"])
    end
  end

  describe "POST /pages" do
    it "creates a page with a slug derived from the title" do
      post pages_path, params: { title: "My FAQ", content: "<p>Q & A</p>" }

      page = seller.pages.last
      expect(page.slug).to eq("my-faq")
      expect(page.title).to eq("My FAQ")
      expect(response).to redirect_to(edit_page_path("my-faq"))
    end

    it "numbers the slug on collision" do
      create(:user_page, pageable: seller, slug: "my-faq", title: "My FAQ")

      post pages_path, params: { title: "My FAQ", content: "<p>Second</p>" }

      expect(seller.pages.order(:id).last.slug).to eq("my-faq-2")
    end

    it "skips reserved slugs so a page never shadows a storefront route" do
      post pages_path, params: { title: "Posts", content: "<p>Shadow?</p>" }

      expect(seller.pages.last.slug).to eq("posts-2")
    end

    it "rejects a blank title" do
      post pages_path, params: { title: "", content: "<p>Hi</p>" }

      expect(seller.pages.count).to eq(0)
      expect(response).to redirect_to(new_page_path)
    end
  end

  describe "PATCH /pages/:slug" do
    let!(:page) { create(:user_page, pageable: seller, slug: "about", title: "About", content: "<p>Old</p>") }

    it "updates title and content" do
      patch page_path("about"), params: { title: "About me", content: "<p>New</p>" }

      expect(page.reload.title).to eq("About me")
      expect(page.content).to eq("<p>New</p>")
    end

    it "refuses to overwrite a custom HTML page from the editor" do
      page.update!(custom_html: "<h1>Agent-built</h1>")

      patch page_path("about"), params: { title: "About me", content: "<p>Manual edit</p>" }

      expect(page.reload.content).to eq("<p>Old</p>")
    end

    it "cannot update another seller's page" do
      other = create(:user_page, slug: "about", title: "Not yours")

      patch page_path("about"), params: { title: "Hijack", content: "" }

      expect(other.reload.title).to eq("Not yours")
    end
  end

  describe "DELETE /pages/:slug" do
    let!(:page) { create(:user_page, pageable: seller, slug: "about", title: "About") }

    it "deletes the page" do
      expect do
        delete page_path("about")
      end.to change { seller.pages.count }.by(-1)
    end

    it "never deletes the profile entry" do
      delete page_path("profile")

      expect(response).to redirect_to(pages_path)
    end
  end

  describe "authorization" do
    it "requires a role that can manage pages" do
      accountant = create(:user)
      create(:team_membership, user: accountant, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
      sign_in accountant

      post pages_path, params: { title: "Nope", content: "" }

      expect(seller.pages.count).to eq(0)
    end
  end
end
