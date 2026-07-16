# frozen_string_literal: true

# Speeds up the asset_preview factories by injecting the metadata that
# ActiveStorage's image/video analyzer would produce for the known-good
# fixture files, instead of shelling out to ImageMagick/ffprobe on every
# `create(:asset_preview*)`.
#
# The shell-out is cheap locally (~0.1s/call) but balloons to ~1.8s/call on CI,
# where many parallel workers each spawn the analyzer binaries and thrash the
# box. asset_preview was the single heaviest factory in the suite-profiling
# pass (#5801): ~96% of its spec file's wall time was factory setup.
#
# Only the specific fixture files the factories attach are pre-analyzed. Any
# other file (e.g. the corrupt/disguised uploads the spec attaches to check
# that the real analyzer rejects them) falls through to a genuine `analyze`, so
# those negative-path tests are unaffected.
#
# To regenerate a row after changing a fixture file: attach it to a blob, call
# `blob.analyze`, and copy `blob.reload.metadata`.
module AssetPreviewAnalysisStub
  KNOWN_METADATA = {
    "kFDzu.png" => { "identified" => true, "width" => 1633, "height" => 512, "analyzed" => true },
    "test-small.jpg" => { "identified" => true, "width" => 25, "height" => 25, "analyzed" => true },
    "sample.gif" => { "identified" => true, "width" => 670, "height" => 500, "analyzed" => true },
    "thing.mov" => { "identified" => true, "width" => 1396.0, "height" => 958.0, "duration" => 2.003167,
                     "display_aspect_ratio" => [698, 479], "audio" => false, "video" => true, "analyzed" => true },
  }.freeze

  # Mirrors the factory's old `preview.file.analyze if attached?`, but takes the
  # fast path for known fixture files.
  def self.analyze(attachment)
    return unless attachment.attached?

    metadata = KNOWN_METADATA[attachment.filename.to_s]
    if metadata
      attachment.blob.update!(metadata: attachment.blob.metadata.merge(metadata))
    else
      attachment.analyze
    end
  end
end
