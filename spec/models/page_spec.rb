# frozen_string_literal: true

require "spec_helper"

describe Page do
  let(:product) { create(:product) }
  let(:user) { create(:user) }

  describe "root pages (custom HTML takeovers)" do
    it "normalizes blank custom_html to nil" do
      page = described_class.create!(pageable: product, custom_html: "")

      expect(page.reload.custom_html).to be_nil
    end

    it "normalizes custom_html to nil when sanitization removes all content" do
      page = described_class.create!(pageable: product, custom_html: %(<script src="https://evil.com/x.js"></script>))

      expect(page.reload.custom_html).to be_nil
    end

    it "allows only one root page per owner" do
      described_class.create!(pageable: user, custom_html: "<h1>Root</h1>")
      duplicate = described_class.new(pageable: user, custom_html: "<h1>Another root</h1>")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:slug]).to be_present
    end

    it "allows a root page alongside slugged pages" do
      described_class.create!(pageable: user, slug: "about", title: "About", content: "<p>Hi</p>")
      root = described_class.new(pageable: user, custom_html: "<h1>Root</h1>")

      expect(root).to be_valid
    end
  end

  describe "content moderation" do
    let(:strategy_result) { Struct.new(:status, :reasoning, keyword_init: true) }

    def stub_strategies(blocklist: "compliant", classifier: "compliant", prompt: "compliant", reasons: [])
      {
        ContentModeration::Strategies::BlocklistStrategy => blocklist,
        ContentModeration::Strategies::ClassifierStrategy => classifier,
        ContentModeration::Strategies::PromptStrategy => prompt,
      }.each do |klass, status|
        allow(klass).to receive(:new).and_return(
          instance_double(klass, perform: strategy_result.new(status:, reasoning: status == "flagged" ? reasons : []))
        )
      end
    end

    before do
      Feature.activate(:content_moderation)
      stub_strategies
    end

    it "blocks a page whose content is flagged and tells the seller what to change" do
      stub_strategies(blocklist: "flagged", reasons: ["OpenAI moderation flagged: violence (score: 0.95, threshold: 0.9)"])

      page = described_class.new(pageable: user, slug: "about", title: "About", custom_html: "<p>Anything</p>")

      expect(page).not_to be_valid
      expect(page.errors[:base].first).to include("violent content")
      expect(page.errors[:base].first).to include("About")
    end

    it "saves a page whose content passes" do
      page = described_class.new(pageable: user, slug: "about", title: "About", custom_html: "<p>Hand-lettered posters</p>")

      expect(page).to be_valid
    end

    it "moderates the root custom HTML takeover as well as slugged pages" do
      stub_strategies(blocklist: "flagged", reasons: ["Matched blocked word: forbidden"])

      expect(described_class.new(pageable: user, custom_html: "<p>Anything</p>")).not_to be_valid
    end

    it "moderates rich text pages written in the editor" do
      stub_strategies(blocklist: "flagged", reasons: ["Matched blocked word: forbidden"])

      expect(described_class.new(pageable: user, slug: "about", title: "About", content: "<p>Anything</p>")).not_to be_valid
    end

    it "does not re-moderate a save that leaves the content alone" do
      page = described_class.create!(pageable: user, slug: "about", title: "About", content: "<p>Hi</p>")
      expect(ContentModeration::ContentExtractor).not_to receive(:new)

      page.update!(slug: "about-us")
    end

    it "skips moderation for VIP creators" do
      stub_strategies(blocklist: "flagged", reasons: ["Matched blocked word: forbidden"])
      allow(user).to receive(:vip_creator?).and_return(true)

      expect(described_class.new(pageable: user, slug: "about", title: "About", content: "<p>Anything</p>")).to be_valid
    end

    it "moderates the submitted HTML rather than the sanitized result" do
      # marquee is dropped by the sanitizer but its text is visible to the
      # extractor, so this text only reaches moderation if the check runs on the
      # submitted document.
      expect(ContentModeration::Strategies::BlocklistStrategy).to receive(:new) do |text:, image_urls:|
        expect(text).to include("hiddenFromSanitizer")
        instance_double(ContentModeration::Strategies::BlocklistStrategy, perform: strategy_result.new(status: "compliant", reasoning: []))
      end

      described_class.new(pageable: user, slug: "about", title: "About", custom_html: "<p>Visible copy</p><marquee>hiddenFromSanitizer</marquee>").valid?
    end

    it "sends a video's poster to the classifier and never the video file itself" do
      # gumroad-private#1728: the video src rode along with the poster, and a
      # file over OpenAI's limit then blocked the publish for good. Asserted at
      # the save rather than on the extractor alone, because the poster has to
      # survive the sanitizer and reach the strategy for the page to publish.
      expect(ContentModeration::Strategies::ClassifierStrategy).to receive(:new) do |text:, image_urls:, max_images:|
        expect(image_urls).to eq(["https://cdn.example.com/frame.jpg"])
        instance_double(ContentModeration::Strategies::ClassifierStrategy,
                        perform: strategy_result.new(status: "compliant", reasoning: []))
      end

      page = described_class.new(
        pageable: user, slug: "about", title: "About",
        custom_html: %(<video src="https://public-files.gumroad.com/clip.mov" poster="https://cdn.example.com/frame.jpg"></video>)
      )

      expect(page).to be_valid
    end

    it "lets a seller unpublish a page without waiting on the moderation service" do
      page = described_class.create!(pageable: user, custom_html: "<p>Hand-lettered posters</p>")
      stub_strategies(blocklist: "flagged", reasons: ["Matched blocked word: forbidden"])
      expect(ContentModeration::ContentExtractor).not_to receive(:new)

      page.custom_html = nil

      expect(page).to be_valid
    end
  end

  describe "slugged pages (first-class Pages)" do
    it "requires a title" do
      page = described_class.new(pageable: user, slug: "about", content: "<p>Hi</p>")

      expect(page).not_to be_valid
      expect(page.errors[:title]).to be_present
    end

    it "rejects slugs with invalid characters" do
      %w[About about_me -about about- a--b].each do |slug|
        page = described_class.new(pageable: user, slug:, title: "About", content: "<p>Hi</p>")
        expect(page).not_to be_valid, "expected #{slug.inspect} to be invalid"
      end
    end

    it "accepts well-formed slugs" do
      %w[about about-me faq2 a-b-c].each do |slug|
        page = described_class.new(pageable: user, slug:, title: "About", content: "<p>Hi</p>")
        expect(page).to be_valid, "expected #{slug.inspect} to be valid: #{page.errors.full_messages}"
      end
    end

    it "rejects reserved slugs that would shadow storefront routes" do
      %w[l d p posts library follow subscribe pages profile edit].each do |slug|
        page = described_class.new(pageable: user, slug:, title: "About", content: "<p>Hi</p>")
        expect(page).not_to be_valid, "expected #{slug.inspect} to be reserved"
        expect(page.errors[:slug]).to include("is reserved")
      end
    end

    it "enforces slug uniqueness per owner but not across owners" do
      described_class.create!(pageable: user, slug: "about", title: "About", content: "<p>Hi</p>")

      duplicate = described_class.new(pageable: user, slug: "about", title: "About again", content: "<p>Hi</p>")
      expect(duplicate).not_to be_valid

      other_owner = described_class.new(pageable: create(:user), slug: "about", title: "About", content: "<p>Hi</p>")
      expect(other_owner).to be_valid
    end

    it "only allows users to have slugged pages" do
      page = described_class.new(pageable: product, slug: "about", title: "About", content: "<p>Hi</p>")

      expect(page).not_to be_valid
      expect(page.errors[:pageable_type]).to be_present
    end

    describe ".generate_slug_for" do
      it "parameterizes the title" do
        expect(described_class.generate_slug_for(user, "About Me!")).to eq("about-me")
      end

      it "falls back to 'page' when the title has no URL-safe characters" do
        expect(described_class.generate_slug_for(user, "!!!")).to eq("page")
      end

      it "numbers the slug when it collides with an existing page" do
        described_class.create!(pageable: user, slug: "about", title: "About", content: "<p>Hi</p>")

        expect(described_class.generate_slug_for(user, "About")).to eq("about-2")
      end

      it "numbers the slug when it collides with a reserved slug" do
        expect(described_class.generate_slug_for(user, "Posts")).to eq("posts-2")
      end

      it "truncates long titles so the slug fits within the length limit" do
        long_title = (["word"] * 40).join(" ") # 199 characters — valid title, but slugs to ~199
        slug = described_class.generate_slug_for(user, long_title)

        expect(slug.length).to be <= Page::MAX_SLUG_LENGTH
        expect(slug).not_to end_with("-")
        expect(described_class.new(pageable: user, slug:, title: long_title, content: "<p>Hi</p>")).to be_valid
      end

      it "keeps numbered candidates within the length limit when the base uses the full length" do
        long_title = (["word"] * 40).join(" ")
        first_slug = described_class.generate_slug_for(user, long_title)
        described_class.create!(pageable: user, slug: first_slug, title: long_title, content: "<p>Hi</p>")

        second_slug = described_class.generate_slug_for(user, long_title)

        expect(second_slug.length).to be <= Page::MAX_SLUG_LENGTH
        expect(second_slug).to end_with("-2")
        expect(second_slug).not_to eq(first_slug)
      end
    end

    it "sanitizes rich text content down to editor-supported markup" do
      page = described_class.create!(
        pageable: user, slug: "about", title: "About",
        content: %(<p>Hello</p><script>alert(1)</script><p onclick="alert(2)">World</p>)
      )

      expect(page.reload.content).to include("<p>Hello</p>")
      expect(page.content).not_to include("<script>")
      expect(page.content).not_to include("onclick")
    end

    it "drops upsell-card nodes that the published static page cannot render" do
      page = described_class.create!(
        pageable: user, slug: "about", title: "About",
        content: %(<p>Hello</p><upsell-card productid="abc"></upsell-card><p>World</p>)
      )

      expect(page.reload.content).to include("<p>Hello</p>")
      expect(page.content).to include("<p>World</p>")
      expect(page.content).not_to include("upsell-card")
    end

    it "strips unsafe URI schemes from links while keeping safe ones" do
      page = described_class.create!(
        pageable: user, slug: "links", title: "Links",
        content: <<~HTML
          <p><a href="https://example.com">safe</a></p>
          <p><a href="javascript:alert(1)">js</a></p>
          <p><a href="JaVaScRiPt:alert(1)">js mixed case</a></p>
          <p><a href="java&#115;cript:alert(1)">js entity-encoded</a></p>
          <p><a href="data:text/html,<script>alert(1)</script>">data uri</a></p>
          <p><a href="vbscript:msgbox(1)">vbscript</a></p>
          <img src="javascript:alert(1)">
        HTML
      )

      content = page.reload.content
      expect(content).to include(%(href="https://example.com"))
      expect(content.downcase).not_to include("javascript:")
      expect(content).not_to include("data:text/html")
      expect(content).not_to include("vbscript:")
    end

    it "keeps custom_html and content independent so an agent takeover wins over rich text" do
      page = described_class.create!(pageable: user, slug: "studio", title: "Studio", content: "<p>Rich text</p>")
      page.update!(custom_html: "<h1>Custom</h1>")

      expect(page.reload.custom_html).to include("Custom")
      expect(page.content).to include("Rich text")
    end
  end

  describe "associations" do
    it "scopes User#page to the root page and User#pages to slugged pages" do
      root = described_class.create!(pageable: user, custom_html: "<h1>Root</h1>")
      slugged = described_class.create!(pageable: user, slug: "about", title: "About", content: "<p>Hi</p>")

      expect(user.reload.page).to eq(root)
      expect(user.pages).to eq([slugged])
    end
  end
end
