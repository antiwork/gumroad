# frozen_string_literal: true

require "spec_helper"

describe "Product content code blocks", type: :system, js: true do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }

  %w[javascript plaintext].each do |language|
    it "changes #{language} with the keyboard without editing the code" do
      text = "const example = 1;"
      content = create(:rich_content, entity: product, description: [
                         { "type" => "codeBlock", "attrs" => { "language" => language },
                           "content" => [{ "type" => "text", "text" => text }] }
                       ])
      login_as seller
      visit "#{edit_link_path(product.unique_permalink)}/content"

      control = find("pre.codeblock-lowlight select")
      expect(control["aria-label"]).to eq("Code language")
      options = control.all("option").map(&:value)
      next_language = options.fetch(options.index(language) + 1)

      find(".tiptap[contenteditable=true]").send_keys(:tab)
      expect(control).to match_css(":focus")
      page.driver.browser.action.send_keys(:arrow_down).perform
      page.driver.browser.action.send_keys(:enter).perform
      expect(control).to match_css(":focus")
      expect(control.value).to eq(next_language)
      save_change
      expect(content.reload.description.first.dig("attrs", "language")).to eq(next_language)
      expect(content.description.first.dig("content", 0, "text")).to eq(text)

      control.send_keys(:arrow_up)
      control.send_keys(:enter)
      expect(control).to match_css(":focus")
      expect(control.value).to eq(language)
      save_change

      visit "#{edit_link_path(product.unique_permalink)}/content"
      expect(find(:select, "Code language").value).to eq(language)
      expect(find("pre.codeblock-lowlight code").text).to eq(text)
    end
  end
end
