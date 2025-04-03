# frozen_string_literal: true

require "spec_helper"

describe Discover::TagPageMetaPresenter do
  describe "#title" do
    context "when one tag with specific title available is provided" do
      it "returns the specific title" do
        expect(described_class.new(["3d-models"], 1000).title).to eq("Professional 3D Modeling Assets")
      end
    end

    context "when one tag without specific title available is provided" do
      it "returns the default title" do
        expect(described_class.new(["tutorial"], 1000).title).to eq("tutorial")
      end
    end

    context "when multiple tags are provided" do
      it "returns the default title" do
        expect(described_class.new(["tag 1", "tag 2"], 1000).title).to eq("tag 1, tag 2")
      end
    end
  end

  describe "#meta_description" do
    context "when one tag with specific meta description available is provided" do
      it "returns the specific meta description" do
        expect(described_class.new(["3d models"], 1000).meta_description).to eq("Browse over 1,000 3D assets including" \
          " 3D models, CG textures, HDRI environments & more for VFX, game development, AR/VR, architecture, and animation.")
      end
    end

    context "when one tag without specific meta description available is provided" do
      it "returns the default meta description" do
        expect(described_class.new(["tutorial"], 1000).meta_description).to eq("Browse over 1,000 unique tutorial" \
          " products published by independent creators on Gumroad. Discover the best things to read, watch, create & more!")
      end
    end

    context "when multiple tags are provided" do
      it "returns the default meta description" do
        expect(described_class.new(["tag 1", "tag 2"], 1000).meta_description).to eq("Browse over 1,000 unique tag 1" \
          " and tag 2 products published by independent creators on Gumroad. Discover the best things to read, watch," \
          " create & more!")
      end
    end
  end
end
