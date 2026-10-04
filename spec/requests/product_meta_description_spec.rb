# frozen_string_literal: true

require "spec_helper"

# The product page must cap its description meta the way the profile (first(300)) and
# wishlist (truncate(160)) pages already do: descriptions run to thousands of characters
# and plaintext_description leaves entities encoded, so the cap must not slice one in half.
# The cut also lands on a word boundary, because this same string is the og/twitter
# description that link previews render verbatim.
describe "product page meta tags", type: :request do
  let(:seller) { create(:user, name: "Meta Seller") }
  let(:long_description) { (1..40).map { |i| "word#{i}" }.join(" ") }

  def rendered_meta_description
    response.body[%r{<meta name="description" content="([^"]*)"}, 1]
  end

  def rendered_og_description
    response.body[%r{<meta property="og:description" content="([^"]*)"}, 1]
  end

  context "when the description is longer than a search snippet" do
    let(:product) { create(:product, user: seller, description: long_description) }

    it "caps the meta description and og:description at 160 characters, on a word boundary" do
      get "http://#{seller.subdomain}/l/#{product.unique_permalink}"

      expect(response).to have_http_status(:ok)

      meta_description = rendered_meta_description
      expect(meta_description).to be_present
      expect(meta_description.length).to be <= 160
      expect(meta_description).to end_with("...")
      expect(meta_description).to start_with("word1 word2")
      expect(rendered_og_description).to eq(meta_description)

      # The cap keeps a whole-word prefix, so the text it drops starts at a word
      # boundary instead of mid-word.
      prefix = meta_description.delete_suffix("...")
      expect(long_description).to start_with(prefix)
      expect(long_description[prefix.length]).to eq(" ")

      # The untruncated description must never reach the document head verbatim.
      # (It legitimately still appears later in the body's Inertia props.)
      expect(response.body.split("<body").first).not_to include(long_description)
    end
  end

  context "when an entity-encoded character sits at the cutoff" do
    # 155 characters before the ampersand, so a 160-character cap applied to the
    # encoded string would keep only "&am" of "&amp;".
    let(:product) { create(:product, user: seller, description: ("a" * 155) + "& chips") }

    it "caps the decoded text instead of splitting the entity" do
      get "http://#{seller.subdomain}/l/#{product.unique_permalink}"

      # The word-boundary cut consumes the space after "&", so the omission abuts the entity.
      expect(rendered_meta_description).to eq(("a" * 155) + "&amp;...")
      expect(rendered_og_description).to eq(("a" * 155) + "&amp;...")
    end
  end

  context "when the description already fits in a snippet" do
    let(:product) { create(:product, user: seller, description: "A short and sweet product description.") }

    it "leaves the description untouched" do
      get "http://#{seller.subdomain}/l/#{product.unique_permalink}"

      expect(rendered_meta_description).to eq("A short and sweet product description.")
      expect(rendered_og_description).to eq("A short and sweet product description.")
    end
  end
end
