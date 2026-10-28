# frozen_string_literal: true

require "spec_helper"

describe ProductBuilds::PlayerDocument do
  describe ".render" do
    it "puts the scripts right after <head>" do
      rendered = described_class.render(%(<!doctype html><html><head><script src="game.js"></script></head></html>), save_data: {})

      expect(rendered).to start_with('<!doctype html><html><head><script data-cfasync="false">')
      expect(rendered.index("gumroad:build-save")).to be < rendered.index(%(src="game.js"))
    end

    it "puts the scripts after the doctype when the page omits <html> and <head>" do
      rendered = described_class.render(%(<!DOCTYPE html>\n<title>Game</title><script src="game.js"></script>), save_data: {})

      expect(rendered).to start_with("<!DOCTYPE html>")
      expect(rendered.index("gumroad:build-save")).to be < rendered.index(%(src="game.js"))
    end

    it "keeps Rocket Loader from deferring the save shim" do
      rendered = described_class.render("<html><head></head></html>", save_data: {})

      expect(rendered).to include('<script data-cfasync="false">(function () {')
    end
  end
end
