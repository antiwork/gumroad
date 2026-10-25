# frozen_string_literal: true

require "spec_helper"

describe "Post-purchase response save recovery", type: :system, js: true do
  [
    [CustomField::TYPE_TEXT, RichContent::SHORT_ANSWER_NODE_TYPE],
    [CustomField::TYPE_LONG_TEXT, RichContent::LONG_ANSWER_NODE_TYPE]
  ].each do |field_type, node_type|
    [404, 500].each do |status|
      it "retries the unchanged #{field_type} answer after HTTP #{status}" do
        product = create(:product)
        purchase = create(:free_purchase, link: product)
        redirect = create(:url_redirect, link: product, purchase:)
        field = create(:custom_field, field_type:, name: "Response", seller: product.user, products: [product], is_post_purchase: true)
        create(:product_rich_content, entity: product, description: [{ "type" => node_type, "attrs" => { "id" => field.external_id, "label" => "Response" } }])
        visit redirect.download_page_url
        page.execute_script <<~JS
          const originalFetch = window.fetch;
          window.responseSaveAttempts = 0;
          window.lastResponseSaveStatus = null;
          window.fetch = async (url, options) => {
            if (String(url).includes('purchase_custom_fields') && ++window.responseSaveAttempts === 1) {
              const payload = JSON.parse(options.body);
              payload.token = 'invalidated-local-test-token';
              const response = #{status} === 404
                ? await originalFetch(url, { ...options, body: JSON.stringify(payload) })
                : new Response(null, { status: 500 });
              window.lastResponseSaveStatus = response.status;
              return response;
            }
            return originalFetch(url, options);
          };
        JS
        input = find_field("Response")
        input.fill_in with: "My answer"
        input.native.send_keys(:tab)
        expect(page).to have_alert(text: "Your response could not be saved. Please try again.")
        expect(page).not_to have_alert(text: "Response saved!")
        expect(page.evaluate_script("window.lastResponseSaveStatus")).to eq(status)
        expect(page).to have_field("Response", with: "My answer", disabled: false)
        expect(purchase.purchase_custom_fields.count).to eq(0)
        input.click
        input.native.send_keys(:tab)
        expect(page).to have_alert(text: "Response saved!")
        expect(purchase.purchase_custom_fields.reload.find_by!(custom_field_id: field.id).value).to eq("My answer")
        expect(purchase.purchase_custom_fields.count).to eq(1)
        input.click
        input.native.send_keys(:tab)
        expect(page.evaluate_script("window.responseSaveAttempts")).to eq(2)
      end
    end
  end
end
