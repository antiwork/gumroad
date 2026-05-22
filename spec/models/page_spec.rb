# frozen_string_literal: true

require "spec_helper"

describe Page do
  let(:user) { create(:user) }

  describe "slug generation" do
    it "derives the slug from the title" do
      page = create(:page, user: user, title: "My Cool Page")
      expect(page.slug).to eq("my-cool-page")
    end

    it "appends -1, -2 on slug collision" do
      create(:page, user: user, title: "Launch")
      page2 = create(:page, user: user, title: "Launch")
      expect(page2.slug).to eq("launch-1")
    end

    it "falls back to 'page' when title is empty after parameterize" do
      page = create(:page, user: user, title: "!!!")
      expect(page.slug).to eq("page")
    end
  end

  describe "profile uniqueness" do
    it "allows one profile page per user" do
      create(:profile_page, user: user)
      expect do
        create(:profile_page, user: user)
      end.to raise_error(ActiveRecord::RecordInvalid, /already exists/)
    end

    it "lets a different user have their own profile page" do
      other = create(:user)
      create(:profile_page, user: user)
      expect do
        create(:profile_page, user: other)
      end.not_to raise_error
    end

    it "allows the user to create a new profile page after deleting the previous one" do
      first = create(:profile_page, user: user)
      first.mark_deleted!
      expect do
        create(:profile_page, user: user)
      end.not_to raise_error
    end
  end

  describe "#publish! / #unpublish!" do
    it "sets published and published_at" do
      page = create(:page, user: user)
      create(:page_version, page: page)
      page.publish!
      expect(page.published).to be(true)
      expect(page.published_at).to be_present
    end

    it "raises when there is no generated content" do
      page = create(:page, user: user)
      expect { page.publish! }.to raise_error(ActiveRecord::RecordInvalid, /Generate the page before publishing/)
    end

    it "raises when the page has html_content but no pinned version" do
      # html_content alone is the editor's working draft — publishing without
      # a versioned snapshot would let the public viewer serve a draft that
      # was never reviewed.
      page = create(:page, user: user, html_content: "<div>working draft</div>")
      expect { page.publish! }.to raise_error(ActiveRecord::RecordInvalid, /Generate the page before publishing/)
      expect(page.reload.published).to be(false)
    end
  end
end
