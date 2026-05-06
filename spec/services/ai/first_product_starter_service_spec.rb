# frozen_string_literal: true

require "spec_helper"

describe Ai::FirstProductStarterService do
  let(:seller) { create(:user, email: "starter-seller@example.com") }
  let(:service) { described_class.new(seller: seller) }

  def valid_options_json
    {
      options: 3.times.map do |i|
        {
          name: "Option #{i + 1}",
          native_type: "digital",
          price_cents: 999,
          description: "<p>" + ("Lorem ipsum sample copy. " * 20) + "</p>",
          rationale_one_line: "Plausible default.",
          is_primary: i.zero?
        }
      end
    }.to_json
  end

  describe "#generate_options" do
    context "with a clear textarea answer", :vcr do
      it "returns a pool of three product options with required fields" do
        result = service.generate_options(
          textarea_answer: "I'm a Figma designer doing SaaS onboarding audits."
        )

        expect(result[:source]).to eq("ai")
        expect(result[:options].length).to eq(3)
        expect(result[:options].count { |o| o[:is_primary] }).to eq(1)
        expect(result[:options].first[:is_primary]).to be(true)

        option = result[:options].first
        expect(option).to include(:name, :native_type, :price_cents, :description, :rationale_one_line, :is_primary)
        expect(option[:native_type]).to be_in(%w[digital course ebook membership])
        expect(option[:price_cents]).to be >= 0
        expect(option[:description].length).to be_between(300, 1500)
      end
    end

    context "with empty textarea" do
      it "returns a pool of three templates tagged with source: 'templates' without calling OpenAI" do
        expect_any_instance_of(OpenAI::Client).not_to receive(:chat)

        result = service.generate_options(textarea_answer: "")

        expect(result[:source]).to eq("templates")
        expect(result[:options].length).to eq(3)
        expect(result[:options].count { |o| o[:is_primary] }).to eq(1)
        expect(result[:options].first[:is_primary]).to be(true)
        expect(result[:options].count { |o| o[:native_type] == "membership" }).to be >= 1
      end

      it "routes whitespace-only input to the template path" do
        expect_any_instance_of(OpenAI::Client).not_to receive(:chat)

        result = service.generate_options(textarea_answer: "   \n  ")

        expect(result[:source]).to eq("templates")
        expect(result[:options].length).to eq(3)
      end
    end

    context "#template_options (called directly when controller is over cap)" do
      it "returns a pool of three templates tagged with source: 'templates' without calling OpenAI" do
        expect_any_instance_of(OpenAI::Client).not_to receive(:chat)

        result = service.template_options

        expect(result[:source]).to eq("templates")
        expect(result[:options].length).to eq(3)
        expect(result[:options].count { |o| o[:is_primary] }).to eq(1)
        expect(result[:options].first[:is_primary]).to be(true)
        expect(result[:options].count { |o| o[:native_type] == "membership" }).to be >= 1
      end
    end

    context "templates fixture" do
      let(:templates) { YAML.load_file(described_class::TEMPLATES_PATH, symbolize_names: true)[:templates] }

      it "ships 20 entries that each carry a [bracketed] placeholder and a valid native_type" do
        expect(templates.length).to eq(20)
        templates.each do |t|
          expect(t[:name]).to match(/\[[^\]]+\]/), "missing placeholder in #{t[:id]}"
          expect(t[:description]).to match(/\[[^\]]+\]/), "missing placeholder in #{t[:id]}"
          expect(t[:native_type]).to be_in(%w[digital course ebook membership])
          expect(t[:price_cents]).to be >= 0
          expect(t[:description].length).to be_between(300, 1500)
          expect(t[:rationale_one_line].length).to be <= 140
        end
      end

      it "includes exactly five membership templates" do
        memberships = templates.select { |t| t[:native_type] == "membership" }
        expect(memberships.length).to eq(5)
      end
    end

    context "when AI returns two options that share a brand noun" do
      it "strips the duplicate brand from the second option" do
        collision_response = {
          "choices" => [{
            "message" => {
              "content" => {
                options: [
                  { name: "Notion CRM template", native_type: "digital", price_cents: 1900, description: "x" * 320, rationale_one_line: "Top of category.", is_primary: true },
                  { name: "Notion power-user paywall", native_type: "membership", price_cents: 1500, description: "x" * 320, rationale_one_line: "Notion fans want more.", is_primary: false },
                  { name: "Watercolor sketch bundle", native_type: "digital", price_cents: 1900, description: "x" * 320, rationale_one_line: "Adjacent.", is_primary: false }
                ]
              }.to_json
            }
          }]
        }
        allow_any_instance_of(OpenAI::Client).to receive(:chat).and_return(collision_response)

        result = service.generate_options(textarea_answer: "I make Notion templates")

        names = result[:options].map { |o| o[:name] }
        notion_count = names.count { |n| n.downcase.include?("notion") }
        expect(notion_count).to eq(1)
      end

      it "leaves an unrelated word that merely contains a brand token alone (community vs unity)" do
        innocent_response = {
          "choices" => [{
            "message" => {
              "content" => {
                options: [
                  { name: "Unity asset pack", native_type: "digital", price_cents: 1900, description: "x" * 320, rationale_one_line: "First.", is_primary: true },
                  { name: "Game-dev community for indie devs", native_type: "membership", price_cents: 1500, description: "x" * 320, rationale_one_line: "Community for buyers.", is_primary: false },
                  { name: "A short course", native_type: "course", price_cents: 4900, description: "x" * 320, rationale_one_line: "Adjacent.", is_primary: false }
                ]
              }.to_json
            }
          }]
        }
        allow_any_instance_of(OpenAI::Client).to receive(:chat).and_return(innocent_response)

        result = service.generate_options(textarea_answer: "I make Unity assets")

        expect(result[:options][1][:name]).to eq("Game-dev community for indie devs")
      end

      it "keeps the original name when stripping the brand would leave it empty" do
        only_brand_response = {
          "choices" => [{
            "message" => {
              "content" => {
                options: [
                  { name: "Notion CRM template", native_type: "digital", price_cents: 1900, description: "x" * 320, rationale_one_line: "First.", is_primary: true },
                  { name: "Notion", native_type: "membership", price_cents: 1500, description: "x" * 320, rationale_one_line: "Second.", is_primary: false },
                  { name: "Watercolor sketches", native_type: "digital", price_cents: 1900, description: "x" * 320, rationale_one_line: "Third.", is_primary: false }
                ]
              }.to_json
            }
          }]
        }
        allow_any_instance_of(OpenAI::Client).to receive(:chat).and_return(only_brand_response)

        result = service.generate_options(textarea_answer: "I make Notion templates")

        expect(result[:options][1][:name]).to eq("Notion")
      end

      it "strips a duplicate brand token even when it appears inside a compound name" do
        compound_response = {
          "choices" => [{
            "message" => {
              "content" => {
                options: [
                  { name: "Unreal asset pack", native_type: "digital", price_cents: 1900, description: "x" * 320, rationale_one_line: "First.", is_primary: true },
                  { name: "Unreal_Engine course", native_type: "course", price_cents: 4900, description: "x" * 320, rationale_one_line: "Second.", is_primary: false },
                  { name: "Indie game-dev membership", native_type: "membership", price_cents: 1500, description: "x" * 320, rationale_one_line: "Third.", is_primary: false }
                ]
              }.to_json
            }
          }]
        }
        allow_any_instance_of(OpenAI::Client).to receive(:chat).and_return(compound_response)

        result = service.generate_options(textarea_answer: "I build Unreal assets")

        names = result[:options].map { |o| o[:name] }
        unreal_count = names.count { |n| n.downcase.include?("unreal") }
        expect(unreal_count).to eq(1)
      end
    end

    context "when the OpenAI call times out twice" do
      it "raises Ai::FirstProductStarterService::MaxRetriesExceededError" do
        allow_any_instance_of(OpenAI::Client).to receive(:chat).and_raise(Faraday::TimeoutError)
        expect do
          service.generate_options(textarea_answer: "I make Mac apps.")
        end.to raise_error(Ai::FirstProductStarterService::MaxRetriesExceededError)
      end
    end

    context "when OpenAI returns malformed JSON on the first attempt" do
      it "retries once and succeeds when the second attempt parses" do
        bad_response = { "choices" => [{ "message" => { "content" => "not json{" } }] }
        good_response = { "choices" => [{ "message" => { "content" => valid_options_json } }] }
        call_count = 0
        allow_any_instance_of(OpenAI::Client).to receive(:chat) do
          call_count += 1
          call_count == 1 ? bad_response : good_response
        end

        result = service.generate_options(textarea_answer: "anything")
        expect(call_count).to eq(2)
        expect(result[:options].length).to eq(3)
      end
    end

    context "when OpenAI returns no membership options" do
      it "rewrites one non-primary option to native_type=membership so the seller sees a recurring path" do
        non_membership_response = {
          "choices" => [{
            "message" => {
              "content" => {
                options: [
                  { name: "A digital pack", native_type: "digital", price_cents: 999, description: "x" * 320, rationale_one_line: "r", is_primary: true },
                  { name: "A short course", native_type: "course", price_cents: 4900, description: "x" * 320, rationale_one_line: "r", is_primary: false },
                  { name: "A niche ebook", native_type: "ebook", price_cents: 1499, description: "x" * 320, rationale_one_line: "r", is_primary: false }
                ]
              }.to_json
            }
          }]
        }
        allow_any_instance_of(OpenAI::Client).to receive(:chat).and_return(non_membership_response)

        result = service.generate_options(textarea_answer: "anything")

        expect(result[:options].count { |o| o[:native_type] == "membership" }).to be >= 1
        expect(result[:options].count { |o| o[:is_primary] }).to eq(1)
      end
    end

    context "when AI returns the primary not at position 0" do
      it "moves the primary to the head of the pool so batch 1 shows it first" do
        primary_in_middle = {
          "choices" => [{
            "message" => {
              "content" => {
                options: [
                  { name: "Filler 1", native_type: "digital", price_cents: 999, description: "x" * 320, rationale_one_line: "r", is_primary: false },
                  { name: "The recommended one", native_type: "digital", price_cents: 1900, description: "x" * 320, rationale_one_line: "Best fit.", is_primary: true },
                  { name: "Filler 3", native_type: "membership", price_cents: 900, description: "x" * 320, rationale_one_line: "r", is_primary: false }
                ]
              }.to_json
            }
          }]
        }
        allow_any_instance_of(OpenAI::Client).to receive(:chat).and_return(primary_in_middle)

        result = service.generate_options(textarea_answer: "anything")

        expect(result[:options].first[:name]).to eq("The recommended one")
        expect(result[:options].first[:is_primary]).to be(true)
      end
    end
  end
end
