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
  # `genre` and `content_type` were added after the initial ship (gumroad-private#1799 follow-up):
  # sample-pack marketplaces like Splice and Loopmasters organize primarily by genre and content
  # type, ahead of tempo bucket, so those were the real gap in the original facet set.
  MUSIC_DEFINITIONS = [
    { name: "genre", label: "Genre", value_type: "enum", values: ["Hip-Hop", "House", "Techno", "Trap", "Pop", "R&B", "Lo-fi", "EDM", "Ambient", "Cinematic"], position: 0 },
    { name: "content_type", label: "Content type", value_type: "enum", values: ["Loop", "One-shot", "MIDI", "Preset", "Stem", "Full track"], position: 1 },
    { name: "format", label: "Format", value_type: "enum", values: ["WAV", "MP3", "AIFF", "MIDI", "Stems"], position: 2 },
    { name: "tempo", label: "Tempo", value_type: "enum", values: ["Under 90 BPM", "90–120 BPM", "120–140 BPM", "Over 140 BPM"], position: 3 },
    { name: "loopable", label: "Loopable", value_type: "boolean", values: [], position: 4 },
    { name: "license", label: "License", value_type: "enum", values: ["Personal", "Commercial", "Royalty-free"], position: 5 },
  ].freeze

  # VRChat buyers don't shop on generic 3D-asset axes (engine/file format) — everything here is a
  # Unity upload by definition. What actually gates a purchase: what kind of item it is, which
  # platform(s) it runs on (VRChat enforces very different poly/component limits for Quest vs PC —
  # a PC-only accessory is unusable on a Quest avatar), and VRChat's own Excellent/Good/Medium/Poor
  # performance-rank system, which buyers already screen for before an upload even shows in-world.
  VRCHAT_DEFINITIONS = [
    { name: "item_type", label: "Item type", value_type: "enum", values: ["Full avatar", "Accessory", "Clothing", "Hair", "Texture / shader", "Animation", "Prop / world asset"], position: 0 },
    { name: "platform", label: "Platform", value_type: "enum", values: ["PC", "Quest", "PC and Quest"], position: 1 },
    { name: "performance_rank", label: "Performance rank", value_type: "enum", values: ["Excellent", "Good", "Medium", "Poor"], position: 2 },
    { name: "rigged", label: "Rigged", value_type: "boolean", values: [], position: 3 },
    { name: "license", label: "License", value_type: "enum", values: ["Personal", "Commercial", "Extended commercial"], position: 4 },
  ].freeze

  # Generic 3D-model marketplace facets (gumroad-private#1796), modeled on how TurboSquid,
  # CGTrader, and Sketchfab actually let buyers narrow a catalog: subject category first
  # (their primary nav/filter), then technical facets. `engine` was dropped from the original
  # draft — format + category already cover the buyer's main "will this work for me" question,
  # and a 7th enum pushed the filter rail past what the other Discover categories carry.
  THREE_D_ASSETS_DEFINITIONS = [
    { name: "subject_category", label: "Category", value_type: "enum", values: ["Character", "Vehicle", "Architecture", "Furniture", "Nature", "Animal", "Weapon", "Food", "Prop", "Environment"], position: 0 },
    { name: "file_format", label: "File format", value_type: "enum", values: ["FBX", "OBJ", "BLEND", "GLB", "VRM", "UnityPackage"], position: 1 },
    { name: "textured_pbr", label: "Textured / PBR", value_type: "boolean", values: [], position: 2 },
    { name: "rigged", label: "Rigged", value_type: "boolean", values: [], position: 3 },
    { name: "animated", label: "Animated", value_type: "boolean", values: [], position: 4 },
    { name: "poly_count", label: "Poly count", value_type: "enum", values: ["Low-poly (under 10k)", "Mid-poly (10k-50k)", "High-poly (over 50k)"], position: 5 },
    { name: "license", label: "License", value_type: "enum", values: ["Personal", "Commercial", "Extended commercial"], position: 6 },
  ].freeze

  DEFINITIONS = {
    # Generic 3D assets (game-dev models, environments, props not tied to VRChat's avatar system)
    # get THREE_D_ASSETS_DEFINITIONS — category-first faceting doesn't transfer to VRChat avatars,
    # whose buyers filter on avatar-specific concerns instead.
    "3d/3d-assets" => THREE_D_ASSETS_DEFINITIONS,
    # VRChat-specific leaves get VRCHAT_DEFINITIONS (gumroad-private#1796) — a different axis set
    # from the generic 3D-assets leaf above, because the buyer question is different.
    "3d/avatars" => VRCHAT_DEFINITIONS,
    "3d/vrchat" => VRCHAT_DEFINITIONS,
    "design/fonts" => [
      { name: "format", label: "Format", value_type: "enum", values: ["OTF", "TTF", "WOFF2"], position: 0 },
      { name: "license", label: "License", value_type: "enum", values: ["Personal", "Commercial", "App embedding"], position: 1 },
      { name: "variable_font", label: "Variable font", value_type: "boolean", values: [], position: 2 },
      { name: "styles", label: "Styles", value_type: "number", values: [], position: 3 },
    ],
    "design/graphics/assets-and-templates" => [
      { name: "template_type", label: "Template type", value_type: "enum", values: ["Presentation", "Social media", "Print", "Web/UI kit", "Mockup", "Branding/Logo", "Resume/CV", "Icon set"], position: 0 },
      { name: "software", label: "Software", value_type: "enum", values: ["Figma", "Photoshop", "Illustrator", "Canva", "Sketch", "After Effects"], position: 1 },
      { name: "file_format", label: "File format", value_type: "enum", values: ["PSD", "AI", "FIG", "SVG", "EPS", "PDF", "PNG"], position: 2 },
      { name: "layered", label: "Layered / editable", value_type: "boolean", values: [], position: 3 },
      { name: "license", label: "License", value_type: "enum", values: ["Personal", "Commercial", "Extended commercial"], position: 4 },
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
