# frozen_string_literal: true

class Ai::ProductDetailsGeneratorService
  class MaxRetriesExceededError < StandardError; end
  class InvalidPromptError < StandardError; end

  PRODUCT_DETAILS_GENERATION_TIMEOUT_IN_SECONDS = 30
  RICH_CONTENT_PAGES_GENERATION_TIMEOUT_IN_SECONDS = 90
  COVER_IMAGE_GENERATION_TIMEOUT_IN_SECONDS = 90

  SUPPORTED_PRODUCT_NATIVE_TYPES = [
    Link::NATIVE_TYPE_DIGITAL,
    Link::NATIVE_TYPE_COURSE,
    Link::NATIVE_TYPE_EBOOK,
    Link::NATIVE_TYPE_MEMBERSHIP
  ].freeze

  MAX_NUMBER_OF_CONTENT_PAGES_TO_GENERATE = 6
  DEFAULT_NUMBER_OF_CONTENT_PAGES_TO_GENERATE = 4

  MAX_PROMPT_LENGTH = 500

  def initialize(current_seller:)
    @current_seller = current_seller
  end

  # @param prompt [String] The user's prompt
  # @return [Hash] with the following keys:
  #   - name: [String] The product name
  #   - description: [String] The product description as an HTML string
  #   - summary: [String] The product summary
  #   - native_type: [String] The product native type
  #   - number_of_content_pages: [Integer] The number of content pages to generate
  #   - price: [Float] The product price
  #   - currency_code: [String] The product price currency code
  #   - price_frequency_in_months: [Integer] The product price frequency in months (1, 3, 6, 12, 24)
  #   - duration_in_seconds: [Integer] The duration of the operation in seconds
  def generate_product_details(prompt:)
    raise InvalidPromptError, "Prompt cannot be blank" if prompt.to_s.strip.blank?

    result, duration = with_retries(operation: "Generate product details", context: prompt) do
      response = openai_client(PRODUCT_DETAILS_GENERATION_TIMEOUT_IN_SECONDS).chat(
        parameters: {
          model: "gpt-4o-mini",
          messages: [
            {
              role: "system",
              content: %Q{
                You are an expert digital product creator. Generate detailed product information based on the user's prompt.

                IMPORTANT: Carefully extract price and currency information from the user's prompt:
                - Look for explicit prices like "for 2 yen", "$10", "€15", "£20", etc.
                - Always use the exact numerical value from the prompt without currency conversion
                - Common currency mappings: "yen" = "jpy", "dollar"/"$" = "usd", "euro"/"€" = "eur", "pound"/"£" = "gbp"
                - Allowed currency codes: #{CURRENCY_CHOICES.keys.join(", ")}
                - If no price is specified, use your best guess based on the product type
                - If no currency is specified, use the seller's default currency: #{current_seller.currency_type}

                Return the following JSON format **only**:
                {
                  "name": "Product name as a string",
                  "number_of_content_pages": 2, // Number of chapters or pages to generate based on the user's prompt. If specified more than #{MAX_NUMBER_OF_CONTENT_PAGES_TO_GENERATE} pages/chapters, generate only #{MAX_NUMBER_OF_CONTENT_PAGES_TO_GENERATE} pages/chapters. If no number is specified, generate #{DEFAULT_NUMBER_OF_CONTENT_PAGES_TO_GENERATE} pages/chapters
                  "description": "Product description as a safe HTML string with only <p>, <ul>, <ol>, <li>, <h2>, <h3>, <h4>, <strong>, and <em> tags; feel free to add emojis. Don't mention the number of pages or chapters in the description.",
                  "summary": "Short summary of the product",
                  "native_type": "Must be one of: #{SUPPORTED_PRODUCT_NATIVE_TYPES.join(", ")}",
                  "price": 4.99, // Extract the exact price from the prompt if specified, otherwise use your best guess
                  "currency_code": "usd", // Extract currency from prompt if specified, otherwise use seller default (#{current_seller.currency_type})
                  "price_frequency_in_months": 1 // Only include if native_type is 'membership' (1, 3, 6, 12, 24)
                }
              }.split("\n").map(&:strip).join("\n")
            },
            {
              role: "user",
              content: prompt.truncate(MAX_PROMPT_LENGTH, omission: "...")
            }
          ],
          response_format: { type: "json_object" },
          temperature: 0.5
        }
      )

      content = response.dig("choices", 0, "message", "content")
      raise "Failed to generate product details - no content returned" if content.blank?

      JSON.parse(content, symbolize_names: true)
    end

    result.merge(duration_in_seconds: duration)
  end

  # @param product_name [String] The product name
  # @return [Hash] with the following keys:
  #   - image_data: [String] The base64 decoded image data
  #   - duration_in_seconds: [Integer] The duration of the operation in seconds
  def generate_cover_image(product_name:)
    image_data, duration = with_retries(operation: "Generate cover image", context: product_name) do
      image_prompt = "Professional, fully covered, high-quality digital product cover image with a modern, clean design and elegant typography. The cover features the product name, '#{product_name}', centered and fully visible, with proper text wrapping, balanced spacing, and padding. Design is optimized to ensure no text is cropped or cut off. Avoid any clipping or cropping of text, and maintain a margin around all edges. Include subtle gradients, minimalist icons, and a harmonious color palette suited for a digital marketplace. The style is sleek, professional, and visually balanced within a square 1024x1024 canvas."
      response = openai_client(COVER_IMAGE_GENERATION_TIMEOUT_IN_SECONDS).images.generate(
        parameters: {
          prompt: image_prompt,
          model: "gpt-image-1",
          size: "1024x1024",
          quality: "medium",
          output_format: "jpeg"
        }
      )

      b64_json = response.dig("data", 0, "b64_json")
      raise "Failed to generate cover image - no image data returned" if b64_json.blank?

      Base64.decode64(b64_json)
    end

    {
      image_data:,
      duration_in_seconds: duration
    }
  end

  # @param product_info [Hash] The product info
  #   - name: [String] The product name
  #   - description: [String] The product description as an HTML string
  #   - native_type: [String] The product native type
  #   - number_of_content_pages: [Integer] The number of content pages to generate
  # @return [Hash] with the following keys:
  #   - pages: [Array<Hash>] The rich content pages
  #   - duration_in_seconds: [Integer] The duration of the operation in seconds
  def generate_rich_content_pages(product_info)
    number_of_content_pages = product_info[:number_of_content_pages] || DEFAULT_NUMBER_OF_CONTENT_PAGES_TO_GENERATE

    pages, duration = with_retries(operation: "Generate rich content pages", context: product_info[:name]) do
      response = openai_client(RICH_CONTENT_PAGES_GENERATION_TIMEOUT_IN_SECONDS).chat(
        parameters: {
          model: "gpt-4o-mini",
          messages: [
            {
              role: "system",
              content: %Q{
                You are creating rich content pages for a digital product.
                Generate exactly #{number_of_content_pages} pages in valid Tiptap JSON format, each page having a title and content array with at least 5-6 meaningful and contextually relevant paragraphs, headings, and lists. Try to match the page titles from the titles of pages/chapters in the description of the product if any.

                CRITICAL: Generate ONLY valid JSON. Always use exactly "type" as the key name, never "type: " or any variation. Ensure all JSON syntax is correct.

                Return a JSON object with pages array. Example output format:
                {
                  "pages": [
                    { "title": "Page 1",
                      "content": [
                        { "type": "heading", "attrs": { "level": 2 }, "content": [ { "type": "text", "text": "Heading" } ] },
                        { "type": "paragraph", "content": [ { "type": "text", "text": "Paragraph 1" } ] },
                        { "type": "orderedList", "content": [ { "type": "listItem", "content": [ { "type": "paragraph", "content": [ { "type": "text", "text": "List item" } ] } ] } ] },
                        { "type": "bulletList", "content": [ { "type": "listItem", "content": [ { "type": "paragraph", "content": [ { "type": "text", "text": "List item" } ] } ] } ] },
                        { "type": "codeBlock", "content": [ { "type": "text", "text": "class Dog\n  def bark\n    puts 'Woof!'\n  end\nend" } ] }
                      ]
                    }
                  ]
                }
              }.split("\n").map(&:strip).join("\n")
            },
            {
              role: "user",
              content: %Q{
              Create detailed content pages for #{product_info[:native_type]} product:
              Product name: "#{product_info[:name]}".
              Number of content pages: #{number_of_content_pages}.
              Product description: "#{product_info[:description]}".
              }
            }
          ],
          response_format: { type: "json_object" },
          temperature: 0.5
        }
      )

      content = response.dig("choices", 0, "message", "content")
      raise "Failed to generate rich content pages - no content returned" if content.blank?

      # Clean up any malformed JSON keys (e.g., "type: " instead of "type")
      cleaned_content = content.gsub(/"type:\s*"/, '"type"')

      JSON.parse(cleaned_content)
    end

    {
      pages: pages["pages"],
      duration_in_seconds: duration
    }
  end

  private
    attr_reader :current_seller

    def openai_client(timeout_in_seconds)
      OpenAI::Client.new(request_timeout: timeout_in_seconds)
    end

    def with_retries(operation:, context: nil, max_tries: 2, delay: 1)
      tries = 0
      start_time = Time.now
      begin
        tries += 1
        result = yield
        duration = Time.now - start_time
        Rails.logger.info("Successfully completed '#{operation}' in #{duration.round(2)}s")
        [result, duration]
      rescue => e
        duration = Time.now - start_time
        if tries < max_tries
          Rails.logger.info("Failed to perform '#{operation}', attempt #{tries}/#{max_tries}: #{context}: #{e.message}")
          sleep(delay)
          retry
        else
          Rails.logger.error("Failed to perform '#{operation}' after #{max_tries} attempts in #{duration.round(2)}s: #{context}: #{e.message}")
          raise MaxRetriesExceededError, "Failed to perform '#{operation}' after #{max_tries} attempts: #{e.message}"
        end
      end
    end
end
