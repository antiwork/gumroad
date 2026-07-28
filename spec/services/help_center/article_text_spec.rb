# frozen_string_literal: true

require "spec_helper"

describe HelpCenter::ArticleText do
  let(:article) { HelpCenter::Article.find_by!(slug: "124-your-gumroad-profile-page") }

  describe ".for" do
    it "returns the article's prose with the HTML markup stripped" do
      text = described_class.for(article)

      expect(text).to include("Your profile allows you to have your own website on Gumroad")
      expect(text).not_to include("<p>")
      expect(text).not_to include("</div>")
    end

    it "puts block elements on their own lines so lists don't read as one run-on sentence" do
      text = described_class.for(article)

      expect(text).to include("Set up your profile\n")
    end

    # Several articles embed screenshots, a few of them as base64 data URLs hundreds of kilobytes
    # long. Passing those through would be useless to a reader and would blow up the response size.
    it "drops images and other non-prose elements" do
      text = described_class.for(HelpCenter::Article.find_by!(slug: "101-designing-your-product-page"))

      expect(text).not_to include("cloudfront.net")
      expect(text).not_to include("base64")
    end

    it "caps the length and points at the live article when it truncates" do
      stub_const("#{described_class}::MAX_LENGTH", 200)

      text = described_class.for(article)

      expect(text.length).to be <= 200
      expect(text).to include("/help/article/124-your-gumroad-profile-page")
    end

    # The cap applies when the text is handed out, never to what is cached, so search can still
    # find a term that sits past the cap in a long article.
    it "caches the full text so a capped read does not shrink what search can see" do
      stub_const("#{described_class}::MAX_LENGTH", 200)

      expect(described_class.for(article).length).to be <= 200
      expect(described_class.plain_text(article).length).to be > 200
    end

    it "reads every article without raising" do
      expect { HelpCenter::Article.all.each { |a| described_class.for(a) } }.not_to raise_error
    end
  end

  describe ".index" do
    it "summarizes every article with the slug needed to read it" do
      index = described_class.index

      expect(index.length).to eq(HelpCenter::Article.count)
      entry = index.find { |a| a[:slug] == "124-your-gumroad-profile-page" }
      expect(entry[:title]).to eq(article.title)
      expect(entry[:url]).to end_with("/help/article/124-your-gumroad-profile-page")
      expect(entry[:category]).to be_present
      # The bodies are deliberately excluded: the whole help center is far too large for one response.
      expect(entry.keys).not_to include(:content)
    end
  end

  describe ".search" do
    it "requires every term to match, so more words narrow the result" do
      broad = described_class.search("profile")
      narrow = described_class.search("profile page")

      expect(broad.length).to be >= narrow.length
      expect(narrow.map { |a| a[:slug] }).to include("124-your-gumroad-profile-page")
    end

    it "matches case-insensitively" do
      expect(described_class.search("PROFILE").map { |a| a[:slug] }).to include("124-your-gumroad-profile-page")
    end

    # The whole point is answering "what does Gumroad say about X". Almost every word a caller
    # would search sits in an article's BODY rather than its headline, and a title-only search
    # returning nothing reads as "Gumroad has nothing on this" — the wrong answer this endpoint
    # exists to prevent. "theme" appears in no title or description.
    it "matches words that appear only in the article body" do
      expect(HelpCenter::Article.all.none? { |a| "#{a.title} #{a.description}".downcase.include?("theme") }).to be(true)

      expect(described_class.search("theme").map { |a| a[:slug] }).to include("124-your-gumroad-profile-page")
    end

    it "ranks a headline match ahead of a body-only match" do
      results = described_class.search("payout").map { |a| a[:slug] }
      headline_match = HelpCenter::Article.all.find { |a| "#{a.title} #{a.description}".downcase.include?("payout") }

      expect(results.length).to be > 1
      expect(results.first).to eq(headline_match.slug)
    end

    # Callers write questions, not keyword lists. When the punctuation stayed glued to the word,
    # "store colors?" searched for the literal "colors?", matched nothing, and read as "Gumroad has
    # no documentation on this".
    it "ignores punctuation so a natural-language question still matches" do
      plain = described_class.search("profile page").map { |a| a[:slug] }

      expect(described_class.search("profile page?").map { |a| a[:slug] }).to eq(plain)
      expect(described_class.search("What's on your profile page?").map { |a| a[:slug] }).to include("124-your-gumroad-profile-page")
    end

    # Found on preview QA: the store agent is told to search the help center in the creator's own
    # words, and every term has to match, so one question word missing from an article's prose hid
    # the article that answered the question. "how do I change my store colors" returned nothing
    # while "change store colors" returned the right article — and the agent reads no results as
    # "Gumroad cannot do this".
    it "drops question words so a full natural-language question matches what its keywords match" do
      keywords = described_class.search("change store colors").map { |a| a[:slug] }
      expect(keywords).to include("124-your-gumroad-profile-page")

      expect(described_class.search("how do I change my store colors?").map { |a| a[:slug] }).to eq(keywords)
      expect(described_class.search("Can I change the font on my product page?").map { |a| a[:slug] })
        .to include("124-your-gumroad-profile-page")
    end

    # Stopwords must not widen a search: dropping them still leaves every topical term required.
    it "still narrows on the meaningful terms after dropping question words" do
      broad = described_class.search("How do I get paid?").map { |a| a[:slug] }
      narrow = described_class.search("How do I get paid by PayPal?").map { |a| a[:slug] }

      expect(narrow.length).to be <= broad.length
      expect(broad).to include(*narrow)
    end

    # Short product vocabulary must survive the stopword pass — "VAT" is a topic on Gumroad, and
    # stripping it would turn a real question into a match against everything. Asserted as a subset
    # rather than an equality: "charge" is a meaningful word and is rightly still required, so the
    # question narrows within the VAT results instead of reproducing them exactly.
    it "keeps short product terms that carry meaning" do
      vat = described_class.search("VAT").map { |a| a[:slug] }
      question = described_class.search("Do I have to charge VAT?").map { |a| a[:slug] }

      expect(question).not_to be_empty
      expect(vat).to include(*question)
      expect(question).to include("10-dealing-with-vat")
    end

    # A query with nothing but function words has no topic. Dropping them all would leave no terms
    # and quietly return the entire help center, which is noise dressed up as an answer.
    it "does not return everything for a query made only of question words" do
      expect(described_class.search("how do I").length).to be < HelpCenter::Article.count
    end

    it "returns the full index for a blank query" do
      expect(described_class.search("  ").length).to eq(HelpCenter::Article.count)
    end

    it "returns the full index for a query that is only punctuation" do
      expect(described_class.search("???").length).to eq(HelpCenter::Article.count)
    end

    it "returns nothing for a query that matches no article" do
      expect(described_class.search("zzzzz-not-a-real-topic")).to eq([])
    end
  end

  describe ".cache_version" do
    # The articles are code, so an article only changes on deploy — and without the deployed
    # revision in the key, an edited article would serve its pre-edit text from the cache forever.
    it "uses the deployed revision so a deploy that edits an article invalidates its cached text" do
      stub_const("REVISION", "abc123def")

      expect(described_class.cache_version).to eq("abc123def")
    end

    it "falls back to the article files' mtimes when there is no deployed revision" do
      stub_const("REVISION", "no-revision")

      expect(described_class.cache_version).to start_with("dev-")
    end

    # A directory's mtime only moves when an entry is added, removed, or renamed. Keying on it meant
    # editing the prose of an article that already existed left the key unchanged, and the cache
    # kept serving the pre-edit text — the staleness these endpoints exist to remove.
    it "changes when an existing article's file is edited, not only when one is added or removed" do
      stub_const("REVISION", "no-revision")
      before = described_class.cache_version

      # Age the file that is CURRENTLY newest. The version is the newest mtime across the articles,
      # so bumping an arbitrary file proves nothing: on a checkout where some other article was
      # touched more recently (an edit in the working tree, say), that file still sets the maximum
      # and the key would be unchanged for reasons unrelated to the behavior under test.
      paths = Dir[Rails.root.join(described_class::CONTENTS_GLOB)]
      real_mtime = File.method(:mtime)
      edited = paths.max_by { |path| real_mtime.call(path) }
      allow(File).to receive(:mtime) do |path|
        path.to_s == edited.to_s ? real_mtime.call(path) + 1.hour : real_mtime.call(path)
      end

      expect(described_class.cache_version).not_to eq(before)
    end

    it "keys the cached text by version, so two revisions cannot share an entry" do
      stub_const("REVISION", "revision-one")
      described_class.for(article)

      expect(Rails.cache.exist?("help_center/article_text/revision-one/#{article.slug}")).to be(true)

      stub_const("REVISION", "revision-two")
      expect(Rails.cache.exist?("help_center/article_text/revision-two/#{article.slug}")).to be(false)
    end
  end
end
