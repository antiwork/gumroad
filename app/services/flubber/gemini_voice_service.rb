# frozen_string_literal: true

require "base64"
require "json"
require "net/http"

module Flubber
  class GeminiVoiceService
    class Error < StandardError; end

    GEMINI_TEXT_MODEL = "gemini-2.5-flash"
    GEMINI_TIMEOUT_SECONDS = 35
    MAX_USER_TRANSCRIPT_CHARS = 8_000

    def call(audio_bytes:, audio_mime_type:, context_image_data_url:, context_metadata:, conversation:, voice_session_id:, available_elements:)
      api_key = GlobalConfig.get("GEMINI_API_KEY")
      raise Error, "Voice assistant is not configured." if api_key.blank?

      prompt = build_prompt(
        context_metadata:,
        conversation:,
        voice_session_id:,
        available_elements:
      )

      raw_text = call_gemini_text(
        api_key:,
        prompt:,
        audio_bytes:,
        audio_mime_type:,
        context_image_data_url:
      )

      parsed = parse_voice_json_response(raw_text)
      guidance_text = parsed[:guidance_text].to_s.strip
      user_transcript = parsed[:user_transcript].to_s.strip[0, MAX_USER_TRANSCRIPT_CHARS]
      raise Error, "Voice assistant returned an empty response." if guidance_text.blank?

      {
        guidance_text: guidance_text,
        user_transcript: user_transcript,
        audio_base64: nil,
        audio_mime_type: nil,
        point_targets: extract_point_targets(guidance_text),
      }
    end

    private
      def build_prompt(context_metadata:, conversation:, voice_session_id:, available_elements:)
        elements_list = available_elements.join(", ")
        <<~TEXT.strip
          You are Flubber, an embedded assistant in the Gumroad product editor.
          You think like a top 1% Gumroad creator — someone who has shipped dozens of products, understands pricing psychology, knows what copy converts, and is brutally honest about what doesn't work.

          Your job is not to explain Gumroad's UI. Your job is to make this product sell.

          TONE
          - Direct, opinionated, no filler
          - Talk like a smart friend who has done this before, not a support bot
          - Never say "great question" or "certainly"
          - Voice-first: short sentences, no bullet points, no markdown

          WHEN ASKED ABOUT COPY OR TITLES
          - Give the actual copy, not advice about copy
          - Lead with the strongest version, explain why in one sentence if needed
          - Good title formula: [outcome] + [specificity] + [who it's for]

          WHEN ASKED ABOUT PRICING
          - Most creators underprice. Default assumption: their price is too low.
          - Ask what transformation the product delivers, then suggest a specific number, not a range.
          - Pay-what-you-want works for audience-building, not revenue.

          WHEN ASKED ABOUT DESCRIPTION
          - First line must hook. No "welcome to my course" or "in this guide you'll learn".
          - Structure: pain → promise → proof → product.
          - Keep it under 150 words for most products.

          WHEN ASKED ABOUT PRODUCT TYPE
          - Digital product = files. Course = structured lessons with upsell potential. Membership = recurring revenue but needs consistent weekly output.
          - Bundle only makes sense after 2+ products exist.

          WHEN ASKED ABOUT THUMBNAILS / COVER
          - Text on image should be the title, nothing else.
          - High contrast, readable at 200px wide.
          - No stock photos of laptops or notebooks.

          WHEN ASKED ABOUT THE PRODUCT URL
          - Short, keyword-rich, no random characters.
          - Bad: /l/xk2p9. Good: /l/freelance-pricing-guide.

          WHEN ASKED ABOUT RECEIPT / POST-PURCHASE
          - The receipt message is the most underused field on Gumroad.
          - Use it to deliver a bonus, ask for a tweet, invite to a community.
          - Template: "Thank you. Here's [bonus]. If this helped, [one ask]."

          WHEN ASKED ABOUT DISTRIBUTION
          - Sequence matters: product page → one audience channel → then Discover.
          - Affiliates only after proof of conversion. Never set up affiliates on a product with zero sales.
          - Emails tab is the highest ROI thing on the platform if they already have buyers.

          WHEN ASKED WHY THEY HAVE NO SALES
          - Be honest: Gumroad doesn't bring traffic. The creator does.
          - Ask where their audience is before suggesting anything.
          - If no audience: Twitter/X, a newsletter, or a niche community is the starting point.
          - Discover helps but only after 5-star reviews exist.

          WHEN REFERENCING A UI ELEMENT
          - Embed [POINT:element-name] using only these element names: #{elements_list}
          - Only point if it's the next physical action they need to take.
          - Never point just to demonstrate the feature.

          guidance_text rules: 1-3 sentences max. If they need copy, write the copy. If they need a number, give the number.

          OUTPUT (required)
          Return ONLY a single JSON object (no markdown fences, no commentary) with exactly these string keys:
          - "user_transcript": Faithful summary of what the creator said in the audio—audience, product, goals, constraints, numbers. This text is stored as chat history; be specific so later turns remember context.
          - "guidance_text": Your Flubber reply following all rules above (including [POINT:...] when appropriate).

          Context for this turn (if screenshot or metadata conflicts with prior conversation, trust screenshot and metadata):
          Voice session id: #{voice_session_id.presence || "unknown"}
          Context metadata (JSON): #{context_metadata}
          Prior conversation (JSON): #{conversation.to_json}
        TEXT
      end

      def call_gemini_text(api_key:, prompt:, audio_bytes:, audio_mime_type:, context_image_data_url:)
        uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{GEMINI_TEXT_MODEL}:generateContent?key=#{api_key}")

        parts = [
          { text: prompt },
          {
            inline_data: {
              mime_type: audio_mime_type,
              data: Base64.strict_encode64(audio_bytes),
            }
          }
        ]

        if context_image_data_url.present?
          parts << {
            inline_data: data_url_to_inline_data(context_image_data_url)
          }
        end

        body = {
          contents: [
            {
              role: "user",
              parts:
            }
          ]
        }

        response = post_json(uri:, body:)
        text = extract_text_response(response)
        raise Error, "Voice assistant returned an empty response." if text.blank?

        text
      end

      def post_json(uri:, body:)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = body.to_json

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: GEMINI_TIMEOUT_SECONDS, read_timeout: GEMINI_TIMEOUT_SECONDS) do |http|
          http.request(request)
        end

        parsed = JSON.parse(response.body)
        return parsed if response.is_a?(Net::HTTPSuccess)

        message = parsed.dig("error", "message").presence || "Voice assistant is temporarily unavailable."
        raise Error, message
      rescue JSON::ParserError
        raise Error, "Voice assistant returned an invalid response."
      rescue Net::OpenTimeout, Net::ReadTimeout, IOError, SocketError
        raise Error, "Voice assistant timed out. Please try again."
      end

      def extract_text_response(response)
        parts = response.dig("candidates", 0, "content", "parts")
        return nil unless parts.is_a?(Array)

        parts.filter_map { |part| part["text"] }.join(" ").strip
      end

      def parse_voice_json_response(raw)
        text = raw.to_s.strip
        return { guidance_text: "", user_transcript: "" } if text.blank?

        stripped = text.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "").strip
        data = try_parse_voice_json(stripped)
        return normalize_voice_json_hash(data) if data

        brace_start = stripped.index("{")
        brace_end = stripped.rindex("}")
        if brace_start && brace_end && brace_end > brace_start
          inner = stripped[brace_start..brace_end]
          data = try_parse_voice_json(inner)
          return normalize_voice_json_hash(data) if data
        end

        Rails.logger.warn("Flubber Gemini voice: non-JSON response, using raw text as guidance only.")
        { guidance_text: stripped, user_transcript: "" }
      end

      def try_parse_voice_json(str)
        JSON.parse(str)
      rescue JSON::ParserError
        nil
      end

      def normalize_voice_json_hash(data)
        return nil unless data.is_a?(Hash)

        g = data["guidance_text"] || data[:guidance_text]
        u = data["user_transcript"] || data[:user_transcript]
        { guidance_text: g.to_s, user_transcript: u.to_s }
      end

      def extract_point_targets(text)
        text.to_s.scan(/\[POINT:([^\]]+)\]/).flatten.uniq
      end

      def data_url_to_inline_data(data_url)
        match = data_url.match(%r{\Adata:(?<mime>image/(?:png|jpe?g));base64,(?<payload>[A-Za-z0-9+/=\r\n]+)\z}i)
        raise Error, "Invalid context image format." unless match

        {
          mime_type: match[:mime].downcase,
          data: Base64.strict_encode64(Base64.strict_decode64(match[:payload]))
        }
      rescue ArgumentError
        raise Error, "Invalid context image encoding."
      end
  end
end
