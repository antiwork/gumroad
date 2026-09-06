# frozen_string_literal: true

require "spec_helper"

describe Ai::StoreAgentApiCatalog do
  describe "Endpoint#expand_path" do
    let(:endpoint) { described_class.find("get_product") }

    it "expands a normal external id into the path" do
      expect(endpoint.expand_path("id" => "abc123")).to eq("/products/abc123")
    end

    it "raises when a required path param is missing" do
      expect { endpoint.expand_path({}) }.to raise_error(ArgumentError, /missing path parameter/i)
    end

    # Security: the value is interpolated into the routed v2 path AFTER the catalog/scope check, so a
    # separator/traversal segment could re-route an authorized call to a different, weaker endpoint.
    it "rejects a path param containing a slash (path injection)" do
      expect { endpoint.expand_path("id" => "../resource_subscriptions") }.to raise_error(ArgumentError, /invalid path parameter/i)
    end

    it "rejects a path param containing a backslash" do
      expect { endpoint.expand_path("id" => "a\\b") }.to raise_error(ArgumentError, /invalid path parameter/i)
    end

    it "rejects a path param containing a dot-segment" do
      expect { endpoint.expand_path("id" => "..") }.to raise_error(ArgumentError, /invalid path parameter/i)
    end

    it "rejects a percent-encoded path param (could decode to a separator)" do
      expect { endpoint.expand_path("id" => "%2e%2e%2fadmin") }.to raise_error(ArgumentError, /invalid path parameter/i)
    end

    # Regression: gumroad-private#1054. LLM-proposed ids sometimes carry non-ASCII characters;
    # unencoded, URI.parse raises URI::InvalidURIError inside the internal rack-test dispatch and
    # the seller sees a 500 "Something went wrong" instead of the API's clean "not found".
    it "percent-encodes a non-ASCII path param so the internal URI stays ascii-only" do
      expanded = endpoint.expand_path("id" => "GJs2આ")
      expect(expanded).to eq("/products/GJs2%E0%AA%86")
      expect { URI.parse("http://api.gumroad.com#{expanded}") }.not_to raise_error
    end

    it "percent-encodes other URI-hostile characters (spaces) without altering safe ids" do
      expect(endpoint.expand_path("id" => "a b")).to eq("/products/a%20b")
      expect(endpoint.expand_path("id" => "abc-DEF_123")).to eq("/products/abc-DEF_123")
    end
  end

  describe ".find" do
    it "returns nil for an unknown id" do
      expect(described_class.find("drop_tables")).to be_nil
    end
  end

  describe ".manifest" do
    it "lists the allowed create_email audience values before the model proposes the write" do
      manifest = described_class.manifest(:write)

      expect(manifest).to include("create_email")
      expect(manifest).to include("audience must be one of: all, audience, customers, seller, followers, follower, product")
    end
  end

  describe "resource subscription endpoints" do
    it "allows listing and deletion but not webhook creation" do
      expect(described_class.find("list_resource_subscriptions")).to be_present
      expect(described_class.find("delete_resource_subscription")).to be_present
      expect(described_class.find("create_resource_subscription")).to be_nil
      expect(described_class.write_ids).not_to include("create_resource_subscription")
      expect(described_class.manifest(:write)).not_to include("Create a webhook resource subscription")
    end

    it "limits listing to Store Agent-owned subscriptions for the requested resource" do
      endpoint = described_class.find("list_resource_subscriptions")

      expect(endpoint.unknown_param_keys_error("resource_name" => "sale")).to be_nil
      expect(endpoint.forced_params).to eq("current_oauth_application_only" => true)
      expect(ResourceSubscription.valid_resource_name?("sale")).to be(true)
    end
  end

  # gumroad-private#1463: with no documentation to read, the agent answered product questions from
  # its own assumptions and told a seller a supported feature did not exist.
  describe "help center endpoints" do
    it "exposes a keyword search over Gumroad's own documentation" do
      endpoint = described_class.find("search_help_articles")

      expect(endpoint).to be_present
      expect(endpoint.read?).to eq(true)
      expect(endpoint.method).to eq(:get)
      expect(endpoint.path).to eq("/help/articles")
      expect(endpoint.params).to eq(%w[query])
      # Public documentation — no seller-data scope needed, so every role can read it.
      expect(endpoint.scope).to be_nil
    end

    it "exposes reading one article in full by slug" do
      endpoint = described_class.find("get_help_article")

      expect(endpoint).to be_present
      expect(endpoint.read?).to eq(true)
      expect(endpoint.path).to eq("/help/articles/:slug")
      expect(endpoint.path_params).to eq(%w[slug])
      expect(endpoint.scope).to be_nil
    end

    it "tells the model to check the docs before declaring something impossible" do
      summary = described_class.find("search_help_articles").summary

      expect(summary).to match(/before telling them something isn't possible/i)
    end
  end

  describe "store theme endpoint" do
    it "exposes the theme as a read the agent can run without confirmation" do
      endpoint = described_class.find("get_user_theme")

      expect(endpoint).to be_present
      expect(endpoint.read?).to eq(true)
      expect(endpoint.method).to eq(:get)
      expect(endpoint.path).to eq("/user/theme")
      expect(endpoint.scope).to eq("view_profile")
    end

    it "has no write counterpart, since the theme is support-applied" do
      expect(described_class.write_ids.grep(/theme/)).to be_empty
    end

    # The false claim that started this: the agent said product pages could not be styled while the
    # seller was looking at product pages rendering these very colours.
    it "states in the manifest that the theme reaches product pages" do
      manifest = described_class.manifest(:read)

      expect(manifest).to include("get_user_theme")
      expect(manifest).to match(/product pages are NOT unstyleable/i)
    end
  end

  # Regression for gumroad-private#1466. The agent could read the profile's custom HTML and nothing
  # else, so a seller with no custom HTML looked to it like a seller with a bare default storefront —
  # and it told him the heading on his own live page did not exist, and that standalone pages and the
  # `gumroad pages` CLI commands were not real Gumroad features.
  describe "default profile layout endpoint" do
    it "exposes the seller's tabs and section headings as a read" do
      endpoint = described_class.find("get_user_profile_layout")

      expect(endpoint).to be_present
      expect(endpoint.read?).to eq(true)
      expect(endpoint.method).to eq(:get)
      expect(endpoint.path).to eq("/user/profile_layout")
      expect(endpoint.scope).to eq("view_profile")
    end

    # The section editor is a structured surface the seller owns, and the agent's only appearance
    # write path is deliberately custom HTML (gumroad-private#984). Reading it must not grow a write.
    it "has no write counterpart, since the seller edits sections in the dashboard" do
      expect(described_class.write_ids.grep(/profile_layout/)).to be_empty
    end

    # The exact inference that produced the incident, stated in the manifest so the model reads it
    # even when it never calls the endpoint.
    it "states in the manifest that no custom HTML does not mean a default profile" do
      manifest = described_class.manifest(:read)

      expect(manifest).to include("get_user_profile_layout")
      expect(manifest).to match(/does NOT mean the profile is Gumroad's untouched default/i)
    end
  end

  describe "standalone storefront pages endpoints" do
    it "exposes reads for the pages list and one page by slug" do
      list = described_class.find("list_pages")
      show = described_class.find("get_page")

      expect(list.read?).to eq(true)
      expect(list.path).to eq("/pages")
      expect(list.params).to be_empty
      expect(list.forced_params).to eq("metadata_only" => true)
      expect(show.read?).to eq(true)
      expect(show.path).to eq("/pages/:id")
      expect(show.path_params).to eq(%w[id])
      expect(show.forced_params).to eq("source_only" => true)
    end

    it "keeps standalone pages read-only until page writes have structural safeguards" do
      expect(described_class.find("update_page")).to be_nil
      expect(described_class.write_ids).not_to include("create_page", "update_page", "delete_page")
    end

    # The claim it made to the seller: that these pages are not a real feature.
    it "states in the manifest that standalone pages are real" do
      expect(described_class.manifest(:read)).to match(/never tell a creator standalone pages do not exist/i)
    end
  end

  describe "profile custom HTML endpoints" do
    it "requires the full profile-page read before either profile-page write" do
      %w[update_user_custom_html edit_user_custom_html].each do |id|
        expect(described_class.find(id).requires_read).to eq("get_user_custom_html")
      end
    end

    it "exposes a targeted-edit write so an existing page never has to be fully regenerated" do
      endpoint = described_class.find("edit_user_custom_html")

      expect(endpoint).to be_present
      expect(endpoint.write?).to eq(true)
      expect(endpoint.method).to eq(:post)
      expect(endpoint.path).to eq("/user/custom_html/edit")
      expect(endpoint.scope).to eq("edit_profile")
      expect(endpoint.params).to eq(%w[find replace])
    end

    it "warns the model that the full-page update is destructive and points at the targeted edit" do
      summary = described_class.find("update_user_custom_html").summary

      expect(summary).to match(/destructive/i)
      expect(summary).to include("edit_user_custom_html")
    end

    it "tells the model a replacement page must carry the whole storefront, not just the requested tweak" do
      summary = described_class.find("update_user_custom_html").summary

      expect(summary).to match(/whole storefront/i)
      expect(summary).to match(/all products/i)
      expect(summary).to match(/dynamically from the gumroad-data JSON/i)
    end

    # The endpoint summary is the only page-authoring guidance the model gets when it proposes
    # this write, so it has to name both capped lists — not just products.
    it "requires the page to disclose a capped product list and a capped post list" do
      summary = described_class.find("update_user_custom_html").summary

      expect(summary).to include("products_total")
      expect(summary).to include("posts_total")
      expect(summary).to match(/show the count for that section/)
    end

    # The creator's name and bio are filled server-side into data-gumroad-field elements — they
    # are not in the injected JSON, and a page that looks for them there renders a blank header.
    it "points page authoring at data-gumroad-field for the creator's name and bio" do
      summary = described_class.find("update_user_custom_html").summary

      expect(summary).to include("data-gumroad-field")
      expect(summary).to match(/NOT in the JSON/)
    end
  end

  describe "create_product endpoint" do
    it "accepts the draft and published opt-outs alongside the product fields" do
      endpoint = described_class.find("create_product")

      expect(endpoint.params).to include("draft", "published")
      expect(endpoint.unknown_param_keys_error("name" => "Book", "price" => 500, "draft" => true)).to be_nil
      expect(endpoint.unknown_param_keys_error("name" => "Book", "price" => 500, "published" => false)).to be_nil
    end

    # The product goes on sale the moment it is created, so the model has to know that before it proposes the write.
    it "tells the model the product publishes by default and how to opt out" do
      summary = described_class.find("create_product").summary

      expect(summary).to match(/published .* immediately/i)
      expect(summary).to include("draft=true")
      expect(summary).to include("published=false")
    end
  end

  describe "product custom HTML endpoints" do
    it "requires the full targeted product-page read before either product-page write" do
      %w[update_product_custom_html edit_product_custom_html].each do |id|
        expect(described_class.find(id).requires_read).to eq("get_product_custom_html")
      end
    end

    it "exposes a read so the agent can inspect a product's current landing page" do
      endpoint = described_class.find("get_product_custom_html")

      expect(endpoint).to be_present
      expect(endpoint.read?).to eq(true)
      expect(endpoint.method).to eq(:get)
      expect(endpoint.path).to eq("/products/:id/custom_html")
      expect(endpoint.scope).to eq("view_sales")
      expect(endpoint.path_params).to eq(%w[id])
    end

    it "exposes a targeted-edit write so an existing product page never has to be fully regenerated" do
      endpoint = described_class.find("edit_product_custom_html")

      expect(endpoint).to be_present
      expect(endpoint.write?).to eq(true)
      expect(endpoint.method).to eq(:post)
      expect(endpoint.path).to eq("/products/:id/custom_html/edit")
      expect(endpoint.scope).to eq("edit_products")
      expect(endpoint.params).to eq(%w[find replace])
    end

    it "exposes the full-page update as a confirmable write accepting only custom_html" do
      endpoint = described_class.find("update_product_custom_html")

      expect(endpoint).to be_present
      expect(endpoint.write?).to eq(true)
      expect(endpoint.method).to eq(:put)
      expect(endpoint.path).to eq("/products/:id")
      expect(endpoint.scope).to eq("edit_products")
      expect(endpoint.params).to eq(%w[custom_html])
    end

    # A custom page replaces the product's native page, buy button included — HTML without a buy
    # element makes the product unpurchasable, so the model must be told before it proposes a page.
    it "warns the model that a page without a buy element makes the product unpurchasable" do
      summary = described_class.find("update_product_custom_html").summary

      expect(summary).to match(/unpurchasable/i)
      expect(summary).to include(%(data-gumroad-action="buy"))
      expect(summary).to match(/price and buy button/i)
    end

    it "warns the model that the full-page update is destructive and points at the targeted edit" do
      summary = described_class.find("update_product_custom_html").summary

      expect(summary).to match(/destructive/i)
      expect(summary).to include("edit_product_custom_html")
    end

    it "tells the model product pages have no gumroad-data JSON, only data-gumroad-field interpolation" do
      summary = described_class.find("update_product_custom_html").summary

      expect(summary).to match(/do NOT receive the gumroad-data JSON/)
      expect(summary).to include("data-gumroad-field")
    end

    # The guardrail copy lives on update_product_custom_html, so the plain product update must not
    # offer a second, warning-free path to the same write.
    it "keeps custom_html out of the generic update_product params" do
      expect(described_class.find("update_product").params).not_to include("custom_html")
    end

    it "includes the declared read precondition in the generated write manifest" do
      manifest = described_class.manifest(:write)

      expect(manifest).to include("update_product_custom_html")
      expect(manifest).to include("requires a successful get_product_custom_html for the same target in this turn")
    end
  end

  describe "public media endpoints" do
    it "exposes an upload write so the agent can host a creator's image for use on a custom page" do
      endpoint = described_class.find("upload_media")

      expect(endpoint).to be_present
      expect(endpoint.write?).to eq(true)
      expect(endpoint.method).to eq(:post)
      expect(endpoint.path).to eq("/media")
      expect(endpoint.scope).to eq("edit_profile")
      expect(endpoint.params).to eq(%w[url name])
    end

    it "exposes a read so the agent can reference previously uploaded files" do
      endpoint = described_class.find("list_media")

      expect(endpoint).to be_present
      expect(endpoint.read?).to eq(true)
      expect(endpoint.scope).to eq("view_profile")
    end

    it "teaches the model that only hosted urls render on custom pages" do
      expect(described_class.find("upload_media").summary).to match(/hosted url/i)
      expect(described_class.find("list_media").summary).to match(/blocked/i)
    end
  end

  describe "paginated list endpoints" do
    # Regression: gumroad-private#1168. list_products exposed no params, so the model could never
    # pass page_key even though the v2 endpoint supports it — any seller with >10 products was
    # invisible past the newest 10, and the model fabricated "I checked page two" claims. Every
    # paginated list read must declare page_key and teach the model to walk pages.
    %w[list_products list_product_subscribers list_emails list_payouts list_sales].each do |id|
      it "#{id} declares page_key so the model can fetch pages past the first" do
        endpoint = described_class.find(id)

        expect(endpoint.params).to include("page_key")
      end
    end

    it "teaches the model that more pages exist when next_page_key is returned" do
      %w[list_products list_product_subscribers list_emails list_payouts].each do |id|
        expect(described_class.find(id).summary).to include("next_page_key")
      end
    end
  end
end
