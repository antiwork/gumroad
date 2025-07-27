# frozen_string_literal: true

require "spec_helper"

describe Ai::ProductDetailsGeneratorService, :vcr do
  let(:current_seller) { create(:user) }
  let(:service) { described_class.new(current_seller:) }

  describe "#generate_product_details" do
    let(:prompt) { "Create a coding tutorial ebook about Ruby on Rails for $29.99" }

    context "with valid prompt" do
      it "generates product details successfully" do
        result = service.generate_product_details(prompt:)

        expect(result).to include(
          :name,
          :description,
          :summary,
          :native_type,
          :number_of_content_pages,
          :price,
          :duration_in_seconds
        )

        expect(result[:name]).to eq("Ruby on Rails Coding Tutorial")
        expect(result[:description]).to eq("<p>Unlock the power of web development with our comprehensive <strong>Ruby on Rails Coding Tutorial</strong>. This ebook is designed for both beginners and experienced developers looking to enhance their skills in Ruby on Rails.</p><ul><li><strong>Learn the Basics:</strong> Understand the fundamental concepts of Ruby and Rails.</li><li><strong>Build Real Applications:</strong> Follow step-by-step instructions to create your own web applications.</li><li><strong>Advanced Techniques:</strong> Explore advanced features and best practices to optimize your projects.</li><li><strong>Hands-On Projects:</strong> Engage in practical projects to solidify your learning.</li></ul><p>Whether you're starting from scratch or looking to refine your skills, this ebook is your ultimate guide to mastering Ruby on Rails! 🚀</p>")
        expect(result[:summary]).to eq("A comprehensive ebook that teaches you Ruby on Rails, from basics to advanced techniques, with hands-on projects.")
        expect(result[:native_type]).to eq("ebook")
        expect(result[:number_of_content_pages]).to eq(4)
        expect(result[:price]).to eq(29.99)
        expect(result[:price_frequency_in_months]).to be_nil
        expect(result[:currency_code]).to eq("usd")
        expect(result[:duration_in_seconds]).to be_a(Numeric)
      end

      it "includes price frequency for membership products" do
        membership_prompt = "Create a quarterly membership for Ruby on Rails developers for $19/month"
        result = service.generate_product_details(prompt: membership_prompt)

        expect(result[:price_frequency_in_months]).to eq(3)
      end
    end

    context "with different currency code" do
      it "returns price in seller's currency" do
        result = service.generate_product_details(prompt: "Create a coding tutorial ebook about Ruby on Rails for 19.99 yen")

        expect(result[:price]).to eq(19.99)
        expect(result[:currency_code]).to eq("jpy")
      end
    end

    context "with blank prompt" do
      it "raises an error" do
        expect { service.generate_product_details(prompt: "") }
          .to raise_error(described_class::InvalidPromptError, "Prompt cannot be blank")
      end
    end

    context "when OpenAI returns invalid JSON" do
      before do
        allow_any_instance_of(OpenAI::Client).to receive(:chat).and_return(
          "choices" => [{
            "message" => {
              "content" => "invalid json response"
            }
          }]
        )
      end

      it "raises an error and retries" do
        expect { service.generate_product_details(prompt:) }
          .to raise_error(described_class::MaxRetriesExceededError)
      end
    end
  end

  describe "#generate_cover_image" do
    let(:product_name) { "Joy of Programming in Ruby" }

    context "with valid product name" do
      it "generates cover image successfully" do
        result = service.generate_cover_image(product_name:)

        expect(result[:image_data]).to be_a(String)
        expect(result[:duration_in_seconds]).to be_a(Numeric)
      end
    end

    context "when OpenAI image generation fails" do
      before do
        allow_any_instance_of(OpenAI::Client).to receive(:images).and_return(double(generate: { "data" => [] }))
      end

      it "raises an error and retries" do
        expect { service.generate_cover_image(product_name:) }
          .to raise_error(described_class::MaxRetriesExceededError)
      end
    end
  end

  describe "#generate_rich_content_pages" do
    let(:product_info) do
      {
        name: "Joy of Programming in Ruby",
        description: "<p>Learn Ruby from the ground up</p>",
        native_type: "ebook",
        number_of_content_pages: 2
      }
    end

    context "with valid product info" do
      it "generates rich content pages successfully" do
        result = service.generate_rich_content_pages(product_info)

        expect(result[:pages].size).to eq(2)
        expect(result[:pages].first["title"]).to eq("Introduction to Ruby")
        expect(result[:pages].first["content"]).to eq([{ "type" => "heading", "attrs" => { "level" => 2 }, "content" => [{ "type" => "text", "text" => "What is Ruby?" }] },
                                                       { "type" => "paragraph",
                                                         "content" =>
                                                         [{ "type" => "text",
                                                            "text" =>
                                                            "Ruby is a dynamic, open-source programming language that is known for its simplicity and productivity. It was created by Yukihiro Matsumoto in the mid-1990s and has since gained immense popularity among developers." }] },
                                                       { "type" => "paragraph",
                                                         "content" =>
                                                         [{ "type" => "text",
                                                            "text" =>
                                                            "One of the key features of Ruby is its elegant syntax that is easy to read and write. This makes it an ideal choice for beginners who are just starting their programming journey." }] },
                                                       { "type" => "heading", "attrs" => { "level" => 3 }, "content" => [{ "type" => "text", "text" => "Why Learn Ruby?" }] },
                                                       { "type" => "paragraph",
                                                         "content" =>
                                                         [{ "type" => "text",
                                                            "text" =>
                                                            "Learning Ruby opens up a world of opportunities, especially in web development. Ruby on Rails, a popular web application framework, is built on Ruby and is widely used by many startups and established companies." }] },
                                                       { "type" => "bulletList",
                                                         "content" =>
                                                         [{ "type" => "listItem",
                                                            "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Easy to learn for beginners." }] }] },
                                                          { "type" => "listItem",
                                                            "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Strong community support." }] }] },
                                                          { "type" => "listItem",
                                                            "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Versatile for various applications." }] }] }] },
                                                       { "type" => "paragraph",
                                                         "content" =>
                                                         [{ "type" => "text",
                                                            "text" =>
                                                            "In this section, we will cover the foundational concepts of Ruby, including variables, data types, and control structures." }] }])
        expect(result[:pages].last["title"]).to eq("Getting Started with Ruby")
        expect(result[:pages].last["content"]).to eq([
                                                       { "type" => "heading", "attrs" => { "level" => 2 }, "content" => [{ "type" => "text", "text" => "Setting Up Your Environment" }] },
                                                       { "type" => "paragraph",
                                                         "content" =>
                                                         [{ "type" => "text",
                                                            "text" =>
                                                            "Before diving into programming, you need to set up your development environment. This involves installing Ruby and a code editor." }] },
                                                       { "type" => "paragraph",
                                                         "content" =>
                                                         [{ "type" => "text",
                                                            "text" =>
                                                            "You can download Ruby from the official website, and we recommend using Visual Studio Code as your code editor due to its rich features and extensions." }] },
                                                       { "type" => "heading", "attrs" => { "level" => 3 }, "content" => [{ "type" => "text", "text" => "Writing Your First Ruby Program" }] },
                                                       { "type" => "paragraph",
                                                         "content" =>
                                                         [{ "type" => "text",
                                                            "text" =>
                                                            "Once your environment is set up, you can create your first Ruby program. Open your code editor, create a new file named 'hello.rb', and write the following code:" }] },
                                                       { "type" => "codeBlock", "content" => [{ "type" => "text", "text" => "puts 'Hello, World!'" }] },
                                                       { "type" => "paragraph",
                                                         "content" =>
                                                         [{ "type" => "text",
                                                            "text" =>
                                                            "Save the file and run it in your terminal using the command `ruby hello.rb`. You should see 'Hello, World!' printed on the screen." }] },
                                                       { "type" => "heading", "attrs" => { "level" => 3 }, "content" => [{ "type" => "text", "text" => "Next Steps" }] },
                                                       { "type" => "paragraph",
                                                         "content" =>
                                                         [{ "type" => "text",
                                                            "text" =>
                                                            "In the following chapters, we will explore more advanced topics such as object-oriented programming, error handling, and building web applications using Ruby on Rails." }] }])
        expect(result[:duration_in_seconds]).to be_a(Numeric)
      end
    end

    context "when OpenAI returns malformed JSON with type colon syntax" do
      before do
        malformed_response = {
          "pages" => [
            {
              "title" => "Chapter 1",
              "content" => [
                { "type: " => "paragraph", "content" => [{ "type" => "text", "text" => "Content" }] }
              ]
            }
          ]
        }

        allow_any_instance_of(OpenAI::Client).to receive(:chat).and_return(
          "choices" => [{
            "message" => {
              "content" => JSON.generate(malformed_response).gsub('"type"', '"type: "')
            }
          }]
        )
      end

      it "cleans up the JSON and parses successfully" do
        result = service.generate_rich_content_pages(product_info)

        expect(result[:pages]).to be_an(Array)
        expect(result[:pages].first["content"].first["type"]).to eq("paragraph")
      end
    end
  end
end
