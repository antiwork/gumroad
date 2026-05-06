# frozen_string_literal: true

class Ai::FirstProductStarterService
  class MaxRetriesExceededError < StandardError; end

  TIMEOUT_SECONDS = 30
  MODEL = "gpt-5.4-nano"
  PROMPT_PATH = Rails.root.join("lib/prompts/first_product_starter/options.md")
  TEMPLATES_PATH = Rails.root.join("lib/first_product_starter/templates.yml")
  MAX_RETRIES = 2
  REASONING_EFFORT = "none"
  PROMPT_CACHE_KEY = "first_product_starter:v7_pool3"
  TEMPLATE_FIELDS = %i[name native_type price_cents description rationale_one_line].freeze
  SHARED_BRAND_TOKENS = %w[notion figma blender lightroom vrchat premiere photoshop canva obsidian unity unreal].freeze
  POOL_SIZE = 3
  PER_GROUP_TARGET = 1
  INSTRUCTIONAL_TYPES = %w[course ebook].freeze
  MEMBERSHIP_PRICE_HIGH_THRESHOLD_CENTS = 2900
  MEMBERSHIP_PRICE_LOW_THRESHOLD_CENTS = 500
  MEMBERSHIP_PRICE_HIGH_FALLBACK_CENTS = 1500
  MEMBERSHIP_PRICE_LOW_FALLBACK_CENTS = 999

  TEMPLATES = YAML.load_file(TEMPLATES_PATH, symbolize_names: true)[:templates].each { |t| t.freeze }.freeze
  SYSTEM_PROMPT = File.read(PROMPT_PATH).freeze
  BRAND_TOKEN_PATTERNS = SHARED_BRAND_TOKENS.each_with_object({}) do |token, h|
    h[token] = /(?<![a-z0-9])#{Regexp.escape(token)}(?![a-z0-9])/i
  end.freeze

  OPTIONS_SCHEMA = {
    type: "object",
    additionalProperties: false,
    required: ["options"],
    properties: {
      options: {
        type: "array",
        minItems: POOL_SIZE,
        maxItems: POOL_SIZE,
        items: {
          type: "object",
          additionalProperties: false,
          required: ["name", "native_type", "price_cents", "description", "rationale_one_line", "is_primary"],
          properties: {
            name: { type: "string", minLength: 1, maxLength: 80 },
            native_type: { type: "string", enum: ["digital", "course", "ebook", "membership"] },
            price_cents: { type: "integer", minimum: 0 },
            description: { type: "string", minLength: 250, maxLength: 1000 },
            rationale_one_line: { type: "string", maxLength: 140 },
            is_primary: { type: "boolean" }
          }
        }
      }
    }
  }.freeze

  def initialize(seller:)
    @seller = seller
  end

  def generate_options(textarea_answer:)
    return template_options if textarea_answer.to_s.strip.blank?

    parsed = with_retries do
      response = openai_client.chat(parameters: build_params(textarea_answer: textarea_answer))
      JSON.parse(response.dig("choices", 0, "message", "content"), symbolize_names: true)
    end
    enforce_one_primary!(parsed[:options])
    ensure_membership_present!(parsed[:options])
    enforce_unique_domains!(parsed[:options])
    interleave_pool_by_type!(parsed[:options])
    parsed.merge(source: "ai")
  end

  def template_options
    random_template_set.merge(source: "templates")
  end

  private
    attr_reader :seller

    def build_params(textarea_answer:)
      params = {
        model: MODEL,
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: textarea_answer.to_s.strip }
        ],
        response_format: {
          type: "json_schema",
          json_schema: { name: "first_product_starter_options", strict: true, schema: OPTIONS_SCHEMA }
        },
        max_completion_tokens: 3000,
        prompt_cache_key: PROMPT_CACHE_KEY,
        user: seller.external_id.to_s
      }
      params[:reasoning_effort] = REASONING_EFFORT unless REASONING_EFFORT == "none"
      params
    end

    def openai_client
      OpenAI::Client.new(request_timeout: TIMEOUT_SECONDS)
    end

    def with_retries
      attempts = 0
      begin
        attempts += 1
        yield
      rescue Faraday::TimeoutError, Faraday::ServerError, JSON::ParserError => e
        raise MaxRetriesExceededError, "OpenAI failed after #{MAX_RETRIES} attempts: #{e.class}" if attempts >= MAX_RETRIES
        retry
      end
    end

    def enforce_one_primary!(options)
      return if options.count { |o| o[:is_primary] } == 1
      options.each_with_index { |o, i| o[:is_primary] = (i == 0) }
    end

    def group_for(option)
      return :membership if option[:native_type] == "membership"
      return :instructional if INSTRUCTIONAL_TYPES.include?(option[:native_type])
      :digital
    end

    def interleave_pool_by_type!(options)
      groups = options.group_by { |o| group_for(o) }

      primary = options.find { |o| o[:is_primary] }
      primary_group = primary ? group_for(primary) : :membership

      base_order = case primary_group
                   when :membership then %i[membership digital instructional]
                   when :digital then %i[digital membership instructional]
                   else %i[instructional membership digital]
      end

      if primary && groups[primary_group]
        groups[primary_group].delete(primary)
        groups[primary_group].unshift(primary)
      end

      arranged = []
      PER_GROUP_TARGET.times do |batch|
        order = base_order.rotate(batch)
        order.each do |g|
          item = groups[g]&.shift
          arranged << item if item
        end
      end

      arranged += (options - arranged)
      options.replace(arranged.first(POOL_SIZE))
    end

    def ensure_membership_present!(options)
      return if options.any? { |o| o[:native_type] == "membership" }
      target = options.find { |o| !o[:is_primary] } || options.last
      target[:native_type] = "membership"
      target[:price_cents] = membership_fallback_price_cents(target[:price_cents].to_i)
    end

    def membership_fallback_price_cents(price_cents)
      return MEMBERSHIP_PRICE_HIGH_FALLBACK_CENTS if price_cents > MEMBERSHIP_PRICE_HIGH_THRESHOLD_CENTS
      return MEMBERSHIP_PRICE_LOW_FALLBACK_CENTS if price_cents < MEMBERSHIP_PRICE_LOW_THRESHOLD_CENTS
      price_cents
    end

    def enforce_unique_domains!(options)
      seen = {}
      options.each do |option|
        name_lower = option[:name].to_s.downcase
        BRAND_TOKEN_PATTERNS.each do |token, pattern|
          next unless name_lower.match?(pattern)
          if seen[token]
            stripped_name = option[:name].gsub(pattern, "").squeeze(" ").strip
            next if stripped_name.empty?
            option[:name] = stripped_name
            option[:rationale_one_line] = option[:rationale_one_line].to_s.gsub(pattern, "").squeeze(" ").strip
          else
            seen[token] = true
          end
        end
      end
    end

    def random_template_set
      memberships = TEMPLATES.select { |t| t[:native_type] == "membership" }
      digitals = TEMPLATES.select { |t| t[:native_type] == "digital" }
      instructional = TEMPLATES.select { |t| INSTRUCTIONAL_TYPES.include?(t[:native_type]) }

      picks = memberships.sample([memberships.length, PER_GROUP_TARGET].min) +
              digitals.sample([digitals.length, PER_GROUP_TARGET].min) +
              instructional.sample([instructional.length, PER_GROUP_TARGET].min)

      picks = picks.first(POOL_SIZE).map { |t| t.slice(*TEMPLATE_FIELDS) }
      picks.first[:is_primary] = true
      picks.drop(1).each { |t| t[:is_primary] = false }
      interleave_pool_by_type!(picks)
      { options: picks }
    end
end
