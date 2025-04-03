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

    def first_stream
      video_information["streams"].first.tap do |stream|
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
