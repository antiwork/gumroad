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
end
