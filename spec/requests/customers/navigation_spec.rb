# frozen_string_literal: true

require "spec_helper"

describe "Sales navigation", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, price_cents: 0) }
  let!(:purchase) { create(:free_purchase, link: product, full_name: "Test Buyer", email: "buyer@example.com") }

  before do
    index_model_records(Purchase)
    login_as seller
  end

  it "preserves the search query when opening a sale and going back" do
    visit customers_path(query: purchase.email)
    expect(page).to have_table("All sales (1)")
    find(:table_row, { "Email" => purchase.email }).click

    expect(page).to have_current_path(customer_sale_path(purchase.external_id))
    expect(page).to have_text("Test Buyer")
    find("a[aria-label='Back to customers']").click
    expect(page).to have_current_path(customers_path(query: purchase.email))
  end

  it "opens a sale after the browser's session storage quota is exhausted" do
    visit customers_path
    expect(page).to have_table("All sales (1)")
    error_name = page.evaluate_script <<~JS
      (() => {
        let value = "";
        for (let size = 1024 * 1024; size >= 1;) {
          try {
            const next = value + "x".repeat(size);
            sessionStorage.setItem("sales-navigation-quota-test", next);
            value = next;
          } catch { size = Math.floor(size / 2); }
        }
        try { sessionStorage.setItem("CustomersPage:canGoBack", "1"); }
        catch (error) { return error.name; }
      })()
    JS
    expect(error_name).to eq("QuotaExceededError")

    find(:table_row, { "Email" => purchase.email }).click
    expect(page).to have_current_path(customer_sale_path(purchase.external_id))
    expect(page).to have_text("Test Buyer")
  ensure
    page.execute_script('sessionStorage.removeItem("sales-navigation-quota-test")')
  end

  ["getItem", "removeItem"].each do |method|
    it "opens a sale when the return-route flag's #{method} is denied" do
      visit customers_path(query: purchase.email)
      expect(page).to have_table("All sales (1)")

      page.execute_script <<~JS, method
        const method = arguments[0];
        window.originalSalesStorageMethod = Storage.prototype[method];
        Storage.prototype[method] = function(key, ...args) {
          if (key === "CustomersPage:canGoBack") throw new DOMException("Storage unavailable", "SecurityError");
          return window.originalSalesStorageMethod.call(this, key, ...args);
        };
      JS

      find(:table_row, { "Email" => purchase.email }).click
      expect(page).to have_current_path(customer_sale_path(purchase.external_id))
      expect(page).to have_text("Test Buyer")
      find("a[aria-label='Back to customers']").click
      expect(page).to have_current_path(customers_path)
    ensure
      page.execute_script <<~JS, method
        if (window.originalSalesStorageMethod) {
          Storage.prototype[arguments[0]] = window.originalSalesStorageMethod;
          delete window.originalSalesStorageMethod;
        }
      JS
    end
  end

  ["QuotaExceededError", "SecurityError"].each do |error_name|
    it "opens a sale when session storage writes raise #{error_name}" do
      visit customers_path
      expect(page).to have_table("All sales (1)")

      page.execute_script <<~JS
        window.originalSalesStorageSetItem = Storage.prototype.setItem;
        Storage.prototype.setItem = () => { throw new DOMException("Storage write unavailable", #{error_name.to_json}); };
      JS

      find(:table_row, { "Email" => "buyer@example.com" }).click

      expect(page).to have_current_path(customer_sale_path(purchase.external_id))
      expect(page).to have_text("Test Buyer")
      find("a[aria-label='Back to customers']").click
      expect(page).to have_current_path(customers_path)
    ensure
      page.execute_script <<~JS
        if (window.originalSalesStorageSetItem) {
          Storage.prototype.setItem = window.originalSalesStorageSetItem;
          delete window.originalSalesStorageSetItem;
        }
      JS
    end
  end
end
