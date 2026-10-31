# frozen_string_literal: true

require "spec_helper"

describe ProductBuilds::PlayerDocument do
  describe ".render" do
    def shim_config(rendered) = JSON.parse(JSON.parse(rendered[/(?:const|var) config = JSON\.parse\((".*")\);\n/, 1]))

    it "puts the scripts right after the doctype, before the page's own scripts" do
      rendered = described_class.render(%(<!doctype html><html><head><script src="game.js"></script></head></html>), save_data: {}, save_url: "/save")

      expect(rendered).to start_with('<!doctype html><script data-cfasync="false">')
      expect(rendered.index("gumroad:build-save")).to be < rendered.index(%(src="game.js"))
    end

    it "puts the IndexedDB shim after the save shim, which hands it the snapshot's slot" do
      rendered = described_class.render(%(<!doctype html><script src="game.js"></script>), save_data: { described_class::INDEXEDDB_SAVE_KEY => "{}" }, save_url: "/save")
      indexeddb_shim = rendered.index(described_class.indexeddb_shim_script)

      expect(rendered.index("gumroad:build-save")).to be < indexeddb_shim
      expect(indexeddb_shim).to be < rendered.index(%(src="game.js"))
      expect(shim_config(rendered)).to include(
        "save" => { described_class::INDEXEDDB_SAVE_KEY => "{}" },
        "indexedDBKey" => described_class::INDEXEDDB_SAVE_KEY,
        "indexedDBSlotGlobal" => described_class::INDEXEDDB_SLOT_GLOBAL,
      )
    end

    it "refuses an IndexedDB shim that is not ASCII or would end its script tag" do
      ["const a = \"é\";", "const a = \"</SCRIPT>\";"].each do |script|
        described_class.instance_variable_set(:@indexeddb_shim_script, nil)
        allow(described_class::INDEXEDDB_SHIM_PATH).to receive(:read).and_return(script)

        expect { described_class.indexeddb_shim_script }.to raise_error(RuntimeError, /not ASCII|end its script tag/)
      end
    ensure
      described_class.instance_variable_set(:@indexeddb_shim_script, nil)
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
      literal = rendered[/(?:const|var) config = JSON\.parse\((".*")\);\n/, 1]

      expect(literal).to be_ascii_only
      expect(literal).not_to include("</script>")
      expect(shim_config(rendered)["save"]).to eq("name" => "Zoë 🎮", "x" => "</script>")
    end

    it "keeps a saved value that contains the template marker as data" do
      rendered = described_class.render("<title>Game</title>", save_data: { "note" => "JSON.parse(__CONFIG__)" }, save_url: "/save")

      config = shim_config(rendered)
      expect(config["saveUrl"]).to eq("/save")
      expect(config["save"]).to eq("note" => "JSON.parse(__CONFIG__)")
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

      expect(rendered).to start_with('<script data-cfasync="false">')
      expect(rendered).to include(ProductBuilds::PlayerDocument::CARRIED_CHANGES_PREFIX)
    end
  end
end
