# frozen_string_literal: true

# Converts seller-uploaded subtitle files (SRT, or VTT without cue settings) into
# WebVTT with explicit positioning settings on every cue.
#
# Why this exists: on iOS, Safari always renders side-loaded caption tracks with
# WebKit's native TextTrack renderer — JW Player's "renderCaptionsNatively: false"
# is ignored there (the player's html5 provider hardcodes native rendering for
# iOS/Safari). WebKit positions cues that carry no explicit settings at the right
# edge of the video instead of centered at the bottom, which made captions
# unreadable for buyers watching purchased videos on iPhones/iPads. SRT has no way
# to express positioning, but WebVTT does: appending "align:center position:50%"
# to each cue's timing line tells WebKit exactly where to draw the cue, and it
# renders centered at the bottom as expected.
# See https://github.com/antiwork/gumroad/issues/6043
#
# The conversion is deliberately forgiving: seller files arrive with BOMs, CRLF
# line endings, stray blank lines, and occasionally malformed cues. A bad cue is
# skipped rather than failing the whole file — a buyer should never lose all
# captions (or hit an error) because one cue is broken.
class SubtitleToVttService
  # Explicit per-cue positioning: horizontally centered ("position:50%" is the
  # cue box's horizontal anchor, "align:center" centers the text within it).
  # The vertical placement is left at the default (bottom of the video).
  CUE_SETTINGS = "align:center position:50%"

  # Matches an SRT or VTT cue timing line, e.g. "00:00:01,000 --> 00:00:04,000"
  # (SRT, comma decimal separator) or "00:01.000 --> 00:04.000" (VTT, hours
  # optional). Anything after the end timestamp is captured as existing cue
  # settings so already-positioned cues are left untouched.
  TIMING_LINE = /\A\s*(?<from>(?:\d{1,2}:)?\d{1,2}:\d{1,2}[.,]\d{1,3})\s*-->\s*(?<to>(?:\d{1,2}:)?\d{1,2}:\d{1,2}[.,]\d{1,3})(?<settings>.*)\z/

  def initialize(content)
    @content = content
  end

  # Returns the file as a WebVTT string. Always returns at least a valid header,
  # even for empty or fully-malformed input.
  def perform
    text = normalize(@content.to_s)
    blocks = text.split(/\n{2,}/).map(&:rstrip).reject(&:empty?)

    if blocks.first&.start_with?("WEBVTT")
      convert_vtt(blocks)
    else
      convert_srt(blocks)
    end
  end

  private
    # Strips the UTF-8 BOM, normalizes CRLF/CR line endings to LF, and scrubs
    # invalid byte sequences so a mis-encoded file degrades instead of raising.
    def normalize(raw)
      text = raw.dup.force_encoding(Encoding::UTF_8)
      text = text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "") unless text.valid_encoding?
      text.delete_prefix("\uFEFF").gsub("\r\n", "\n").tr("\r", "\n")
    end

    def convert_srt(blocks)
      cues = blocks.filter_map { |block| convert_cue(block, keep_non_cue_blocks: false) }
      (["WEBVTT"] + cues).join("\n\n") + "\n"
    end

    # A file that is already WebVTT passes through, but each cue that carries no
    # settings still gets the explicit positioning appended — a bare VTT cue is
    # misplaced by iOS WebKit exactly like a converted SRT cue would be.
    # Non-cue blocks (the header, NOTE/STYLE/REGION blocks) pass through as-is.
    def convert_vtt(blocks)
      header = blocks.shift
      converted = blocks.filter_map { |block| convert_cue(block, keep_non_cue_blocks: true) }
      ([header] + converted).join("\n\n") + "\n"
    end

    # Converts a single cue block. Returns nil for blocks that should be dropped:
    # malformed cues (no parseable timing line) and, for SRT input, cues with no
    # visible text. SRT's numeric cue counters are dropped — they'd be legal VTT
    # cue identifiers, but they carry no meaning for playback.
    def convert_cue(block, keep_non_cue_blocks:)
      lines = block.split("\n")
      timing_index = lines.index { |line| TIMING_LINE.match?(line) }

      if timing_index.nil?
        return keep_non_cue_blocks ? block : nil
      end

      match = TIMING_LINE.match(lines[timing_index])
      text_lines = lines[(timing_index + 1)..].to_a
      return nil if text_lines.all? { |line| line.strip.empty? }

      settings = match[:settings].strip
      settings = CUE_SETTINGS if settings.empty?
      timing = "#{vtt_timestamp(match[:from])} --> #{vtt_timestamp(match[:to])} #{settings}"

      # VTT cue identifiers (lines before the timing line) are kept — they can be
      # targeted by ::cue(#id) styling. SRT's numeric counters are dropped above
      # via keep_non_cue_blocks being false for SRT input.
      identifier_lines = keep_non_cue_blocks ? lines[0...timing_index] : []
      (identifier_lines + [timing] + text_lines).join("\n")
    end

    # SRT timestamps use a comma before the milliseconds ("00:00:01,000") where
    # VTT requires a dot; components are also padded so sloppy files like
    # "0:00:01,5" become the "00:00:01.500" shape VTT parsers expect.
    def vtt_timestamp(timestamp)
      time, fraction = timestamp.strip.split(/[.,]/)
      components = time.split(":").map { |component| component.rjust(2, "0") }
      "#{components.join(":")}.#{fraction.to_s.ljust(3, "0")}"
    end
end
