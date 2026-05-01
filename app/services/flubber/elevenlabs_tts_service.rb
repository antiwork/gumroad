# frozen_string_literal: true

require "base64"
require "json"
require "net/http"

module Flubber
  class ElevenlabsTtsService
    class Error < StandardError; end

    API_HOST = "api.elevenlabs.io"
    # Default "Rachel" (Voice Library). Free API plans often cannot use library voices — set ELEVENLABS_VOICE_ID.
    DEFAULT_VOICE_ID = "21m00Tcm4TlvDq8ikWAM"
    DEFAULT_MODEL_ID = "eleven_turbo_v2_5"
    MAX_TEXT_CHARS = 2_500
    REQUEST_TIMEOUT_SECONDS = 60

    def self.synthesize(text:)
      new.synthesize(text:)
    end

    def synthesize(text:)
      api_key = GlobalConfig.get("ELEVENLABS_API_KEY").to_s.strip.presence
      raise Error, "ElevenLabs is not configured." if api_key.blank?

      cleaned = text.to_s.strip
      cleaned = cleaned[0, MAX_TEXT_CHARS] if cleaned.length > MAX_TEXT_CHARS
      raise Error, "Nothing to speak." if cleaned.blank?

      voice_id = GlobalConfig.get("ELEVENLABS_VOICE_ID").to_s.strip.presence || DEFAULT_VOICE_ID
      model_id = GlobalConfig.get("ELEVENLABS_MODEL_ID").to_s.strip.presence || DEFAULT_MODEL_ID

      uri = URI("https://#{API_HOST}/v1/text-to-speech/#{voice_id}")
      uri.query = URI.encode_www_form("output_format" => "mp3_44100_128")

      request = Net::HTTP::Post.new(uri)
      request["xi-api-key"] = api_key
      request["Content-Type"] = "application/json"
      request["Accept"] = "audio/mpeg"
      request.body = { text: cleaned, model_id: model_id }.to_json

      response = Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: true,
        open_timeout: REQUEST_TIMEOUT_SECONDS,
        read_timeout: REQUEST_TIMEOUT_SECONDS
      ) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        message = parse_error_message(response.body)
        Rails.logger.warn("Flubber ElevenLabs HTTP #{response.code}: #{message.to_s.truncate(500)}")
        raise Error, message.presence || "ElevenLabs request failed (HTTP #{response.code})."
      end

      body_bytes = response.body.to_s.b
      if body_bytes.blank?
        Rails.logger.warn("Flubber ElevenLabs returned an empty audio body.")
        raise Error, "ElevenLabs returned empty audio."
      end

      {
        audio_base64: Base64.strict_encode64(body_bytes),
        audio_mime_type: "audio/mpeg",
      }
    rescue JSON::ParserError
      raise Error, "ElevenLabs returned an invalid response."
    rescue Net::OpenTimeout, Net::ReadTimeout, IOError, SocketError
      raise Error, "ElevenLabs timed out."
    end

    private
      def parse_error_message(body)
        return nil if body.blank?

        hash = JSON.parse(body)
        detail = hash["detail"]
        case detail
        when Hash
          detail["message"].presence || detail.to_json
        when String
          detail
        when Array
          detail.filter_map { |d| d.is_a?(Hash) ? d["msg"] || d["message"] : d }.join("; ").presence
        else
          hash["message"].presence
        end
      end
  end
end
