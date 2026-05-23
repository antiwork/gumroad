# frozen_string_literal: true

require "test_helper"

class DiscoverTagPageMetaPresenterTest < ActiveSupport::TestCase
  self.described_class = Discover::TagPageMetaPresenter



  context_ Discover::TagPageMetaPresenter do
  context_ "#title" do
  context_ "when one tag with specific title available is provided" do
  test "returns the specific title" do
          expect(described_class.new(["3d-models"], 1000).title).to eq("Professional 3D Modeling Assets")
        end
      end

  context_ "when one tag without specific title available is provided" do
  test "returns the default title" do
          expect(described_class.new(["tutorial"], 1000).title).to eq("tutorial")
        end
      end

  context_ "when multiple tags are provided" do
  test "returns the default title" do
          expect(described_class.new(["tag 1", "tag 2"], 1000).title).to eq("tag 1, tag 2")
        end
      end

  context_ "when a single empty tag is provided" do
  test "does not raise and returns the default title" do
          expect { described_class.new([""], 1000).title }.not_to raise_error
          expect(described_class.new([""], 1000).title).to eq("")
        end
      end

  context_ "when a single whitespace-only tag is provided" do
  test "does not raise and returns the default title" do
          expect { described_class.new([" "], 1000).title }.not_to raise_error
          expect(described_class.new([" "], 1000).title).to eq(" ")
        end
      end
    end

  context_ "#meta_description" do
  context_ "when one tag with specific meta description available is provided" do
  test "returns the specific meta description" do
          expect(described_class.new(["3d models"], 1000).meta_description).to eq("Browse over 1,000 3D assets including" \
            " 3D models, CG textures, HDRI environments & more for VFX, game development, AR/VR, architecture, and animation.")
        end
      end

  context_ "when one tag without specific meta description available is provided" do
  test "returns the default meta description" do
          expect(described_class.new(["tutorial"], 1000).meta_description).to eq("Browse over 1,000 unique tutorial" \
            " products published by independent creators on Gumroad. Discover the best things to read, watch, create & more!")
        end
      end

  context_ "when multiple tags are provided" do
  test "returns the default meta description" do
          expect(described_class.new(["tag 1", "tag 2"], 1000).meta_description).to eq("Browse over 1,000 unique tag 1" \
            " and tag 2 products published by independent creators on Gumroad. Discover the best things to read, watch," \
            " create & more!")
        end
      end

  context_ "when a single empty tag is provided" do
  test "does not raise and returns the default meta description" do
          expect { described_class.new([""], 1000).meta_description }.not_to raise_error
        end
      end

  context_ "when a single whitespace-only tag is provided" do
  test "does not raise and returns the default meta description" do
          expect { described_class.new([" "], 1000).meta_description }.not_to raise_error
        end
      end
    end
  end
end
