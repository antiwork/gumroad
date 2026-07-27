# frozen_string_literal: true

class Ffprobe
  attr_reader :path

  def initialize(path)
    @path = File.expand_path(path)
  end

  def parse
    raise ArgumentError, "File not found #{path}" unless File.exist?(path)

    OpenStruct.new(first_stream)
  end

  private
    def calculate_framerate(r_frame_rate)
      rfr = r_frame_rate.split("/")

      # framerate is typically in "24/1" string format
      rfr[1].to_i == 0 ? rfr[0] : (rfr[0].to_i / rfr[1].to_i)
    end

    # How far a player will rotate this video before showing it. Phones film in
    # one fixed sensor orientation and record a rotation instead of rewriting the
    # pixels, so a video that looks portrait can be stored landscape with a
    # quarter-turn attached. Older files carry it as a "rotate" tag; newer ones
    # carry a display matrix in the stream's side data, where the angle is
    # negative for the same clockwise turn. We only care about the turn itself,
    # so the sign is dropped and the angle normalized to 0/90/180/270.
    #
    # This mirrors what the streamio-ffmpeg gem already does for every other
    # video format we accept (FFMPEG::Movie#width/#height swap themselves when a
    # rotation is present) — only the .mov path reads ffprobe directly and so had
    # to do it here. See https://github.com/antiwork/gumroad-private/issues/1392
    def rotation(stream)
      tagged = stream.dig("tags", "rotate")
      matrix = stream["side_data_list"]&.find { |data| data["rotation"].present? }&.fetch("rotation", nil)
      degrees = (tagged || matrix).to_i.abs % 360
      degrees % 90 == 0 ? degrees : 0
    end

    # Swap the stored dimensions for a quarter-turned video so callers get the
    # size the buyer actually sees, not the size on disk. A 1920x1080 file with a
    # quarter turn displays as 1080x1920, and everything downstream (the player
    # frame on the content page, the HLS preset picked for the transcode, which
    # auto-rotates its output) wants the displayed size.
    def display_dimensions(stream)
      return stream unless [90, 270].include?(rotation(stream))

      stream.merge("width" => stream["height"], "height" => stream["width"])
    end

    def first_stream
      display_dimensions(video_information["streams"].first).tap do |stream|
        stream.merge!(framerate: calculate_framerate(stream["r_frame_rate"]))
      end
    end

    def video_information
      @video_information ||= begin
        result = `#{command}`
        parse_json(result)
      end
    end

    def parse_json(result)
      JSON.parse(result)
    end

    def command
      %(ffprobe -print_format json -show_streams -select_streams v:0 "#{path}" 2> /dev/null)
    end
end
