# frozen_string_literal: true

# Canonical per-category attribute definitions for faceted Discover filtering.
#
# These have to live in code rather than only in `db/seeds`, because the seed file that
# introduced them sits under `010_development_staging_test/` and never runs in production —
# so the Fonts facets shipped with no rows behind them on prod. `Onetime::SeedTaxonomyAttributes`
# applies this registry to any environment; the dev/staging/test seed reads the same source so
# the two cannot drift.
#
# Adding a category is a data-only change here. `name` is the ES filter-token prefix and is
# permanent once products carry values for it; `label` and `values` are display-side and may
# be edited freely.
class TaxonomyAttributeDefinitions
  MUSIC_DEFINITIONS = [
    { name: "format", label: "Format", value_type: "enum", values: ["WAV", "MP3", "AIFF", "MIDI", "Stems"], position: 0 },
    { name: "tempo", label: "Tempo", value_type: "enum", values: ["Under 90 BPM", "90–120 BPM", "120–140 BPM", "Over 140 BPM"], position: 1 },
    { name: "loopable", label: "Loopable", value_type: "boolean", values: [], position: 2 },
    { name: "license", label: "License", value_type: "enum", values: ["Personal", "Commercial", "Royalty-free"], position: 3 },
  ].freeze

  DEFINITIONS = {
    "design/fonts" => [
      { name: "format", label: "Format", value_type: "enum", values: ["OTF", "TTF", "WOFF2"], position: 0 },
      { name: "license", label: "License", value_type: "enum", values: ["Personal", "Commercial", "App embedding"], position: 1 },
      { name: "variable_font", label: "Variable font", value_type: "boolean", values: [], position: 2 },
      { name: "styles", label: "Styles", value_type: "number", values: [], position: 3 },
    ],
    # Root plus the four children named in gumroad-private#1799: attributes do not inherit, and
    # sample packs file under the root as well as its children.
    "music-and-sound-design" => MUSIC_DEFINITIONS,
    "music-and-sound-design/dance-and-theater" => MUSIC_DEFINITIONS,
    "music-and-sound-design/instruments" => MUSIC_DEFINITIONS,
    "music-and-sound-design/sound-design" => MUSIC_DEFINITIONS,
    "music-and-sound-design/vocal" => MUSIC_DEFINITIONS,
  }.freeze

  # Maps each configured slug path to its Taxonomy, skipping paths whose taxonomy is absent.
  def self.each_taxonomy_with_definitions
    return to_enum(:each_taxonomy_with_definitions) unless block_given?

    DEFINITIONS.each do |slug_path, definitions|
      taxonomy = taxonomy_for(slug_path)
      next if taxonomy.nil?

      yield taxonomy, definitions
    end
  end

  # Walks the slug path so "design/fonts" cannot match a same-named leaf under another parent
  # (`photoshop` and `canva` each appear under several branches).
  def self.taxonomy_for(slug_path)
    slug_path.split("/").reduce(nil) do |parent, slug|
      taxonomy = Taxonomy.find_by(slug:, parent:)
      return nil if taxonomy.nil?

      taxonomy
    end
  end
end
