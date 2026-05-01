# frozen_string_literal: true

require "base64"
require "json"

class Api::FlubberController < Api::Internal::BaseController
  class FlubberUpstreamError < StandardError
    attr_reader :http_status

    def initialize(message, http_status: :internal_server_error)
      super(message)
      @http_status = http_status
    end
  end

  FLUBBER_OPENAI_MODEL = "gpt-4o-mini"
  FLUBBER_OPENAI_TIMEOUT = 30
  # Prior turns only (user + assistant pairs); excludes the current `message` param.
  MAX_CONVERSATION_MESSAGES = 40
  MAX_MESSAGE_CHARS = 8_000
  MAX_CONTEXT_IMAGE_BYTES = 1.5.megabytes
  MAX_METADATA_CHARS = 2_000
  MAX_VOICE_AUDIO_BYTES = 5.megabytes
  VOICE_AUDIO_MIME_TYPES = ["audio/webm", "audio/webm;codecs=opus", "audio/mp4", "audio/mpeg", "audio/wav"].freeze

  before_action :authenticate_user!
  after_action :verify_authorized

  AVAILABLE_ELEMENTS = %w[product-type product-name cover-upload pricing publish-button].freeze

  def chat
    authorize Link, :new?

    api_key = GlobalConfig.get("OPENAI_ACCESS_TOKEN")
    if api_key.blank?
      render json: { success: false, error: "Assistant is not configured." }, status: :service_unavailable
      return
    end

    message = params[:message].to_s.strip
    if message.blank?
      render json: { success: false, error: "Message is required." }, status: :bad_request
      return
    end

    if message.length > MAX_MESSAGE_CHARS
      render json: { success: false, error: "Message is too long." }, status: :bad_request
      return
    end

    elements = permitted_elements

    metadata = normalize_context_metadata

    system_prompt = <<~TEXT.strip
      You are Flubber, a helper on the Gumroad product editor page.
      You are an execution-focused digital product coach: practical, concise, and conversion-minded.
      Use the latest screenshot, context metadata, and the user's latest message as the source of truth.
      Ignore unrelated navigation/sidebar UI unless the user explicitly asks about it.
      If screenshot/metadata conflicts with conversation history, trust screenshot+metadata.

      Intent routing:
      - If user asks to write/provide content (title, description, outline, copy), give ready-to-paste content first.
      - If user asks for setup instructions, provide the best next action and concrete fill-in guidance.
      - Do not force setup steps when user requested copy/content.

      Response quality:
      - Be specific about what to type/select and why it matters.
      - Use short paragraphs or bullets when helpful.
      - Keep unnecessary boilerplate out.
      - If user asks about creating an ebook or what to set up first, prioritize choosing product type first.

      Available UI elements you can point at:
      #{elements.join(", ")}

      If referencing a UI element, embed exactly: [POINT:element-name]
      Only use element names from the list above. Never invent names.
      Context metadata (JSON):
      #{metadata}
    TEXT

    conversation = normalize_conversation(conversation_param)
    context_image_data_url = normalize_context_image_data_url
    reply_text = call_openai(
      api_key:,
      system_prompt:,
      conversation:,
      user_message: message,
      context_image_data_url:
    )

    render json: { success: true, reply: reply_text }
  rescue FlubberUpstreamError => e
    Rails.logger.warn("Flubber chat upstream error: #{e.message}")
    render json: { success: false, error: e.message }, status: e.http_status
  rescue StandardError => e
    Rails.logger.error("Flubber chat failed: #{e.full_message}")
    ErrorNotifier.notify(e)
    render json: { success: false, error: "Something went wrong. Please try again." }, status: :internal_server_error
  end

  def voice_turn
    authorize Link, :new?

    audio_upload = params[:audio_chunk]
    if audio_upload.blank?
      render json: { success: false, error: "Audio is required." }, status: :bad_request
      return
    end

    if audio_upload.size.to_i > MAX_VOICE_AUDIO_BYTES
      render json: { success: false, error: "Audio payload is too large." }, status: :bad_request
      return
    end

    audio_mime_type = audio_upload.content_type.to_s
    unless VOICE_AUDIO_MIME_TYPES.any? { |allowed| audio_mime_type.start_with?(allowed) }
      render json: { success: false, error: "Unsupported audio format." }, status: :bad_request
      return
    end

    service_response = Flubber::GeminiVoiceService.new.call(
      audio_bytes: audio_upload.read,
      audio_mime_type:,
      context_image_data_url: normalize_context_image_data_url,
      context_metadata: normalize_context_metadata,
      conversation: normalize_conversation(parse_json_param(:conversation)),
      voice_session_id: params[:voice_session_id].to_s,
      available_elements: permitted_elements_from(parse_json_param(:available_elements))
    )

    guidance_text = service_response[:guidance_text].to_s
    audio_base64 = service_response[:audio_base64]
    audio_mime_type = service_response[:audio_mime_type]
    tts_skip_reason = nil
    tts_error_detail = nil
    tts_hint_code = nil

    eleven_key = elevenlabs_api_key
    if guidance_text.present? && eleven_key
      speakable = flubber_speakable_text_for_tts(guidance_text)
      if speakable.blank?
        tts_skip_reason = "empty_speakable"
      else
        begin
          tts = Flubber::ElevenlabsTtsService.synthesize(text: speakable)
          audio_base64 = tts[:audio_base64]
          audio_mime_type = tts[:audio_mime_type]
        rescue StandardError => e
          tts_skip_reason = "elevenlabs_error"
          tts_error_detail = e.message.to_s.truncate(400)
          tts_hint_code = flubber_elevenlabs_failure_hint_code(e.message)
          Rails.logger.warn("Flubber ElevenLabs TTS skipped: #{e.class}: #{e.message}")
        end
      end
    elsif guidance_text.present?
      tts_skip_reason = "no_elevenlabs_api_key"
    end

    payload = {
      success: true,
      guidance_text: service_response[:guidance_text],
      user_transcript: service_response[:user_transcript].to_s,
      audio_base64:,
      audio_mime_type:,
      point_targets: service_response[:point_targets],
    }
    payload[:tts_skip_reason] = tts_skip_reason if tts_skip_reason.present?
    payload[:tts_error_detail] = tts_error_detail if tts_error_detail.present? && Rails.env.development?
    payload[:tts_hint_code] = tts_hint_code if tts_hint_code.present?

    render json: payload
  rescue Flubber::GeminiVoiceService::Error => e
    render json: { success: false, error: e.message }, status: :bad_gateway
  rescue FlubberUpstreamError => e
    render json: { success: false, error: e.message }, status: e.http_status
  rescue StandardError => e
    Rails.logger.error("Flubber voice turn failed: #{e.full_message}")
    ErrorNotifier.notify(e)
    render json: { success: false, error: "Something went wrong. Please try again." }, status: :internal_server_error
  end

  private
    def permitted_elements
      requested = Array(params[:available_elements]).map(&:to_s)
      permitted_elements_from(requested)
    end

    def permitted_elements_from(requested)
      allowed = requested & AVAILABLE_ELEMENTS
      allowed.presence || AVAILABLE_ELEMENTS
    end

    def conversation_param
      params[:conversation].presence || params.dig(:flubber, :conversation)
    end

    def context_image_data_url_param
      params[:context_image_data_url].presence || params.dig(:flubber, :context_image_data_url)
    end

    def context_metadata_param
      params[:context_metadata].presence || params.dig(:flubber, :context_metadata)
    end

    def parse_json_param(key)
      value = params[key]
      return value unless value.is_a?(String)

      JSON.parse(value)
    rescue JSON::ParserError
      raise FlubberUpstreamError.new("Invalid #{key} payload.", http_status: :bad_request)
    end

    def flubber_speakable_text_for_tts(raw)
      raw.to_s.gsub(/\[POINT:[^\]]+\]/, " ").squeeze(" ").strip
    end

    def elevenlabs_api_key
      GlobalConfig.get("ELEVENLABS_API_KEY").to_s.strip.presence
    end

    def flubber_elevenlabs_failure_hint_code(message)
      m = message.to_s
      return "elevenlabs_library_voice_not_on_plan" if m.match?(/library voices|Free users cannot/i)

      nil
    end

    def normalize_context_image_data_url
      data_url = context_image_data_url_param
      return nil if data_url.blank?

      match = data_url.match(%r{\Adata:image/(?<format>png|jpe?g);base64,(?<payload>[A-Za-z0-9+/=\r\n]+)\z}i)
      raise FlubberUpstreamError.new("Invalid context image format.", http_status: :bad_request) unless match

      decoded = Base64.strict_decode64(match[:payload])
      if decoded.bytesize > MAX_CONTEXT_IMAGE_BYTES
        raise FlubberUpstreamError.new("Context image is too large.", http_status: :bad_request)
      end

      "data:image/#{match[:format].downcase};base64,#{Base64.strict_encode64(decoded)}"
    rescue ArgumentError
      raise FlubberUpstreamError.new("Invalid context image encoding.", http_status: :bad_request)
    end

    def normalize_context_metadata
      raw = context_metadata_param
      return "{}" if raw.blank?

      metadata_hash =
        if raw.is_a?(ActionController::Parameters)
          raw.to_unsafe_h
        elsif raw.is_a?(Hash)
          raw
        else
          {}
        end

      clean = {
        current_route: metadata_hash["current_route"] || metadata_hash[:current_route],
        current_tab: metadata_hash["current_tab"] || metadata_hash[:current_tab],
        field_state: metadata_hash["field_state"] || metadata_hash[:field_state],
      }.compact

      json = clean.to_json
      json.length > MAX_METADATA_CHARS ? json[0, MAX_METADATA_CHARS] : json
    end

    def normalize_conversation(raw)
      items =
        Array(raw).filter_map do |entry|
          h =
            if entry.is_a?(ActionController::Parameters)
              entry.permit(:role, :content).to_h
            elsif entry.respond_to?(:to_unsafe_h)
              entry.to_unsafe_h
            elsif entry.is_a?(Hash)
              entry.stringify_keys
            else
              next
            end

          role = h["role"].to_s.strip
          content = h["content"].to_s.strip
          next if content.blank?
          next unless %w[user assistant].include?(role)

          content = content[0, MAX_MESSAGE_CHARS]
          { role:, content: }
        end

      items = items.last(MAX_CONVERSATION_MESSAGES)
      align_conversation_turns(items)
    end

    # Drop a leading assistant (invalid without prior user) and trailing user (current message belongs in `message`).
    def align_conversation_turns(items)
      items = items.drop_while { |m| m[:role] == "assistant" }
      items.pop while items.last&.dig(:role) == "user"
      items
    end

    def call_openai(api_key:, system_prompt:, conversation:, user_message:, context_image_data_url:)
      latest_user_content = [
        { type: "text", text: user_message }
      ]
      if context_image_data_url.present?
        latest_user_content << {
          type: "image_url",
          image_url: { url: context_image_data_url },
        }
      end

      openai_messages = [
        { role: "system", content: system_prompt },
        *conversation.map { |m| { role: m[:role], content: m[:content] } },
        { role: "user", content: latest_user_content }
      ]

      client = OpenAI::Client.new(access_token: api_key, request_timeout: FLUBBER_OPENAI_TIMEOUT)
      response = client.chat(
        parameters: {
          model: FLUBBER_OPENAI_MODEL,
          messages: openai_messages,
          max_tokens: 700,
          temperature: 0.7
        }
      )

      content = response.dig("choices", 0, "message", "content")
      raise FlubberUpstreamError.new("Empty assistant response", http_status: :bad_gateway) if content.blank?

      content.to_s.strip
    rescue Faraday::UnauthorizedError, Faraday::ForbiddenError => e
      message =
        if Rails.env.development?
          openai_error_message_from_response(e).presence || "invalid OpenAI API key — set OPENAI_ACCESS_TOKEN in .env (see .env.example)."
        else
          "Assistant is not available."
        end
      raise FlubberUpstreamError.new(message, http_status: :service_unavailable)
    rescue Faraday::BadRequestError => e
      api_msg = openai_error_message_from_response(e)
      message =
        if Rails.env.development? && api_msg.present?
          api_msg
        else
          "Assistant request could not be completed."
        end
      raise FlubberUpstreamError.new(message, http_status: :bad_gateway)
    rescue Faraday::ClientError => e
      if e.response_status == 429
        raise FlubberUpstreamError.new("Assistant is busy. Please try again in a moment.", http_status: :too_many_requests)
      end

      raise FlubberUpstreamError.new("Assistant is temporarily unavailable.", http_status: :bad_gateway)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::ServerError, Faraday::ParsingError
      raise FlubberUpstreamError.new("Assistant is temporarily unavailable.", http_status: :bad_gateway)
    end

    def openai_error_message_from_response(faraday_error)
      body = faraday_error.response_body
      return nil if body.blank?

      hash = JSON.parse(body)
      hash.dig("error", "message").presence
    rescue JSON::ParserError, TypeError
      nil
    end
end
