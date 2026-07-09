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

  # Regression guard for gumroad-private#984: the agent's only "profile appearance" write used to be
  # update_user_custom_html, so a "change my store color" request replaced the native storefront
  # with a generated page. The catalog must expose a scoped design endpoint and steer the model
  # away from custom_html for appearance tweaks.
  describe "profile design endpoints" do
    it "exposes a scoped storefront design write with exactly the three design params" do
      endpoint = described_class.find("update_profile_design")
      expect(endpoint).to be_present
      expect(endpoint.write?).to eq(true)
      expect(endpoint.scope).to eq("edit_profile")
      expect(endpoint.params).to match_array(%w[background_color highlight_color font])
      expect(endpoint.path).to eq("/user/profile_design")
    end

    it "exposes a read for the current design" do
      endpoint = described_class.find("get_profile_design")
      expect(endpoint).to be_present
      expect(endpoint.read?).to eq(true)
    end

    it "steers appearance requests away from update_user_custom_html in its summary" do
      summary = described_class.find("update_user_custom_html").summary
      expect(summary).to include("update_profile_design")
      expect(summary).to match(/never use this for color/i)
    end
  end
end
