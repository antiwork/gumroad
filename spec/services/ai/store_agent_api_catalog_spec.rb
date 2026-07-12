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
  end

  describe ".find" do
    it "returns nil for an unknown id" do
      expect(described_class.find("drop_tables")).to be_nil
    end
  end

  describe "profile custom HTML endpoints" do
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
end
