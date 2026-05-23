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
      create(:product_page, user: user, link: create(:product, user: user), title: "Launch")
      page2 = create(:product_page, user: user, link: create(:product, user: user), title: "Launch")
      expect(page2.slug).to eq("launch-1")
    end

    it "falls back to 'page' when title is empty after parameterize" do
      page = create(:page, user: user, title: "!!!")
      expect(page.slug).to eq("page")
    end

    it "retries with a fresh counter when DB raises RecordNotUnique" do
      # Simulate the TOCTOU window: generate_slug picked "launch" because
      # the existence query ran before the winning row committed. The DB
      # unique index then rejects the insert. The retry must regenerate a
      # fresh slug and successfully save.
      create(:product_page, user: user, link: create(:product, user: user), title: "Launch") # slug "launch"

      page = Page.new(user: user, link: create(:product, user: user), title: "Launch")
      first_call = true
      allow(page).to receive(:_create_record).and_wrap_original do |orig, *args, &block|
        if first_call
          first_call = false
          raise ActiveRecord::RecordNotUnique, "Duplicate entry 'launch' for key 'index_pages_on_user_id_and_slug'"
        else
          orig.call(*args, &block)
        end
      end

      expect { page.save! }.not_to raise_error
      expect(page.slug).to eq("launch-1")
    end

    it "gives up after SLUG_RETRY_LIMIT attempts" do
      create(:product_page, user: user, link: create(:product, user: user), title: "Launch")
      page = Page.new(user: user, link: create(:product, user: user), title: "Launch")
      allow(page).to receive(:_create_record).and_raise(
        ActiveRecord::RecordNotUnique.new("Duplicate entry 'launch' for key 'index_pages_on_user_id_and_slug'")
      )
      expect { page.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "title default" do
    it "falls back to the product's name when the page is owned by a product" do
      product = create(:product, user: user, name: "My Course")
      page = Page.create!(user: user, link: product)
      expect(page.title).to eq("My Course")
    end

    it "falls back to 'Untitled page' on a profile-owned page when no title is given" do
      page = Page.create!(user: user, is_profile: true)
      expect(page.title).to eq("Untitled page")
    end

    it "leaves an explicit title untouched" do
      page = Page.create!(user: user, is_profile: true, title: "Hand-rolled")
      expect(page.title).to eq("Hand-rolled")
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

  describe "#mark_deleted!" do
    # Regression: mark_deleted! appends "-deleted-<id>" to free up the slug
    # for reuse. If the original slug is already near the 100-char max,
    # naive concatenation breaks the length validation and the soft-delete
    # raises — leaving the page un-deletable.
    it "soft-deletes a page whose slug is already at the maximum length" do
      page = create(:page, user: user, title: "a")
      page.update_column(:slug, "a" * 100)
      expect { page.mark_deleted! }.not_to raise_error
      expect(page.reload.deleted_at).to be_present
      expect(page.slug.length).to be <= 100
      expect(page.slug).to end_with("-deleted-#{page.id}")
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

  describe "#apply_new_version!" do
    it "applies when no parent expectation is given" do
      page = create(:page, user: user)
      v1 = create(:page_version, page: page, html: "<section>v1</section>", prompt: "x")
      expect(page.apply_new_version!(v1)).to be(true)
      expect(page.reload.html_content).to include("v1")
    end

    it "applies when the page's latest version still matches expected_parent_id" do
      page = create(:page, user: user)
      v1 = create(:page_version, page: page, html: "<section>v1</section>", prompt: "x")
      page.apply_new_version!(v1)
      v2 = create(:page_version, page: page, html: "<section>v2</section>", prompt: "y", parent: v1)

      expect(page.apply_new_version!(v2, expected_parent_id: v1.id)).to be(true)
      expect(page.reload.html_content).to include("v2")
    end

    it "skips the apply when a newer version has landed since the job was enqueued" do
      page = create(:page, user: user)
      v1 = create(:page_version, page: page, html: "<section>v1</section>", prompt: "x")
      v2 = create(:page_version, page: page, html: "<section>v2</section>", prompt: "y", parent: v1)
      # Another job has already applied v2 — that's now the latest.
      page.apply_new_version!(v2)

      # A stale job that branched from v1 finishes and tries to apply its own version.
      stale = create(:page_version, page: page, html: "<section>stale</section>", prompt: "z", parent: v1)
      expect(page.apply_new_version!(stale, expected_parent_id: v1.id)).to be(false)
      expect(page.reload.html_content).to include("v2")
      expect(page.html_content).not_to include("stale")
    end
  end
end
