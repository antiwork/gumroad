# frozen_string_literal: true

require "spec_helper"

describe ProductBuilds::PlayerDocument do
  describe ".render" do
    it "puts the scripts right after the doctype, before the page's own scripts" do
      rendered = described_class.render(%(<!doctype html><html><head><script src="game.js"></script></head></html>), save_data: {}, save_url: "/save")

      expect(rendered).to start_with('<!doctype html><script data-cfasync="false">')
      expect(rendered.index("gumroad:build-save")).to be < rendered.index(%(src="game.js"))
    end

    it "is not misled by a <head> inside a comment, and keeps leading comments before the doctype" do
      rendered = described_class.render(%(<!-- built by x -->\n<!doctype html><!-- <head> --><title>Game</title>), save_data: {}, save_url: "/save")

      expect(rendered).to start_with(%(<!-- built by x -->\n<!doctype html><script data-cfasync="false">))
    end

    it "keeps a UTF-8 byte order mark at the start" do
      rendered = described_class.render("\xEF\xBB\xBF<!doctype html><title>Game</title>".b, save_data: {}, save_url: "/save")

      expect(rendered).to start_with(%(\xEF\xBB\xBF<!doctype html><script data-cfasync="false">).b)
    end

    it "writes the save as ASCII, so a page in another encoding reads it the same" do
      rendered = described_class.render("<title>Game</title>", save_data: { "name" => "Zoë 🎮", "x" => "</script>" }, save_url: "/save")
      json = rendered[/JSON\.parse\((".*?")\);/, 1]

      expect(json).to be_ascii_only
      expect(JSON.parse(JSON.parse(json.gsub("\\u003c", "<").gsub("\\u003e", ">")))).to eq("name" => "Zoë 🎮", "x" => "</script>")
    end

    it "puts the scripts at the very start of a page with no doctype" do
      rendered = described_class.render(%(<script src="game.js"></script>), save_data: {}, save_url: "/save")

      expect(rendered).to start_with('<script data-cfasync="false">')
    end

    it "puts the scripts after the doctype when the page omits <html> and <head>" do
      rendered = described_class.render(%(<!DOCTYPE html>\n<title>Game</title><script src="game.js"></script>), save_data: {}, save_url: "/save")

      expect(rendered).to start_with("<!DOCTYPE html>")
      expect(rendered.index("gumroad:build-save")).to be < rendered.index(%(src="game.js"))
    end

    it "keeps Rocket Loader from deferring the save shim" do
      rendered = described_class.render("<html><head></head></html>", save_data: {}, save_url: "/save")

      expect(rendered).to include('<script data-cfasync="false">(function () {')
    end
  end
end
