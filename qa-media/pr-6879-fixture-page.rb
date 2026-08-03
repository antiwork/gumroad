# frozen_string_literal: true

out = []
seller = User.find_by(email: "seller@gumroad.com")

html = <<~'HTM'
  <div id="wrap">
    <h1>QA6879 catalogue</h1>
    <p id="status">rendering...</p>
    <ul id="list"></ul>
    <button id="more" data-testid="load-more">Load more</button>
    <pre id="log"></pre>
  </div>
  <script>
    // The injected gumroad-data payload is page 1 (capped at MAX_ITEMS). The bridge
    // scripts are appended after this one, so read them on load.
    var el = document.getElementById("gumroad-data");
    var data = el ? JSON.parse(el.textContent) : {};
    var products = data.products || [];
    var listEl = document.getElementById("list");
    var logEl = document.getElementById("log");
    function render(items, tag) {
      items.forEach(function (p) {
        var li = document.createElement("li");
        li.setAttribute("data-src", tag);
        li.textContent = tag + " - " + p.name + " " + (p.price || "");
        listEl.appendChild(li);
      });
    }
    render(products.slice(0, 2), "page1");
    document.getElementById("status").textContent =
      "page 1: showing " + Math.min(2, products.length) + " of " + (data.products_total || products.length) +
      " products, from the injected gumroad-data payload";
    window.addEventListener("load", function () {
      logEl.textContent = "window.gumroadProducts.request is a function: " +
        (typeof ((window.gumroadProducts || {}).request) === "function");
    });
    document.getElementById("more").addEventListener("click", function () {
      if (!window.gumroadProducts) { logEl.textContent += "\nNO BRIDGE"; return; }
      window.gumroadProducts.request({ offset: 2, limit: 2 }).then(function (r) {
        logEl.textContent += "\ngumroad:products reply -> success=" + r.success + " offset=" + r.offset +
          " limit=" + r.limit + " productsTotal=" + r.productsTotal + " received=" + r.products.length +
          " requestId=" + r.requestId;
        render(r.products, "page2");
        document.getElementById("status").textContent =
          "page 2 fetched through the gumroad:products bridge (offset 2, limit 2 of " + r.productsTotal + ")";
      });
    });
  </script>
HTM

page = seller.page || seller.build_page
page.save!(validate: false) unless page.persisted?
out << "SANITIZED len=#{Ai::PageSanitizer.sanitize(html).length} (input #{html.length}) -> using update_columns"
page.update_columns(custom_html: html)
out << "STORED len=#{seller.reload.page.custom_html.to_s.length}"
out << "VISIBLE custom_landing_page_visible=#{seller.custom_landing_page_visible?}"
puts "\n===MARKS===\n" + out.join("\n")
