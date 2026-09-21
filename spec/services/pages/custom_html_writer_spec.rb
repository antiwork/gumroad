# frozen_string_literal: true

require "spec_helper"

describe Pages::CustomHtmlWriter do
  describe ".edit! with checksums (the server-built HTML undo)" do
    let(:user) { create(:user) }
    let(:original) { "<section><p>Keep this instruction.</p><footer>Unchanged</footer></section>" }
    let(:find) { "<p><strong>Keep this instruction.</strong></p>" }
    let(:replace) { "<p>Keep this instruction.</p>" }
    let(:current_page) { user.reload.custom_html }
    let(:expected_digest) { Digest::SHA256.hexdigest(current_page) }
    let(:result_digest) { Digest::SHA256.hexdigest(Ai::PageSanitizer.sanitize_with_report(current_page.sub(find) { replace }).html.to_s) }

    before do
      Feature.activate_user(:custom_html_pages, user)
      user.update!(custom_html: "<section><p><strong>Keep this instruction.</strong></p><footer>Unchanged</footer></section>")
    end

    def guarded_edit(**overrides)
      described_class.edit!(user, find:, replace:, expected_custom_html_sha256: expected_digest, result_custom_html_sha256: result_digest, **overrides)
    end

    it "restores the exact page when both digests hold" do
      page_before = current_page
      result = guarded_edit

      expect(result.success?).to be(true)
      expect(result.previous_custom_html).to eq(page_before)
      expect(Digest::SHA256.hexdigest(user.reload.custom_html)).to eq(result_digest)
      expect(user.custom_html).not_to include("<strong>")
    end

    [
      { expected_custom_html_sha256: "not-a-digest" },
      { result_custom_html_sha256: "ABCDEF" },
      { result_custom_html_sha256: nil },
      { expected_custom_html_sha256: nil },
    ].each do |override|
      it "refuses malformed or single checksums #{override.inspect} without writing" do
        page_before = current_page
        result = guarded_edit(**override)

        expect(result.error).to eq(described_class::INVALID_CHECKSUMS_ERROR)
        expect(user.reload.custom_html).to eq(page_before)
      end
    end

    it "refuses a stale page whose snippet still matches, without writing" do
      stale_digest = expected_digest
      user.update!(custom_html: current_page.sub("</section>", "<footer>Added later</footer></section>"))
      changed_page = user.reload.custom_html

      result = guarded_edit(expected_custom_html_sha256: stale_digest)

      expect(result.error).to eq(described_class::PAGE_CHANGED_ERROR)
      expect(user.reload.custom_html).to eq(changed_page)
    end

    it "refuses before saving when the sanitized result would not match the recorded original" do
      page_before = current_page
      # Transactional specs would hide a post-save rollback (the writer's Rollback is swallowed by
      # the outer example transaction), so this only holds if the check runs before the save.
      expect(user).not_to receive(:save!)

      result = guarded_edit(result_custom_html_sha256: "b" * 64)

      expect(result.error).to eq(described_class::RESULT_MISMATCH_ERROR)
      expect(user.reload.custom_html).to eq(page_before)
    end

    it "refuses a nonidempotent sanitized result without leaking a save through an outer transaction" do
      page_before = current_page
      replacement = %(#{replace}<iframe src="data:text/html,example"></iframe>)
      once = Ai::PageSanitizer.sanitize_with_report(page_before.sub(find) { replacement }).html
      twice = Ai::PageSanitizer.sanitize_with_report(once).html
      expect(once).not_to eq(twice)
      check = described_class.check_guarded_edit(page_before, find:, replace: replacement,
                                                              expected_custom_html_sha256: expected_digest,
                                                              result_custom_html_sha256: Digest::SHA256.hexdigest(once))
      expect(check.error).to eq(described_class::RESULT_MISMATCH_ERROR)

      user.class.transaction(requires_new: true) do
        result = guarded_edit(replace: replacement, result_custom_html_sha256: Digest::SHA256.hexdigest(once))
        expect(result.error).to eq(described_class::RESULT_MISMATCH_ERROR)
      end
      expect(user.reload.custom_html).to eq(page_before)
    end

    it "checks the result digest against the sanitized output rather than the raw splice" do
      unsafe_replace = %(<p>Keep this instruction.</p><script src="https://evil.example.com/x.js"></script>)
      raw_splice = current_page.sub(find) { unsafe_replace }
      sanitized = Ai::PageSanitizer.sanitize_with_report(raw_splice).html.to_s
      expect(sanitized).not_to include("evil.example.com")

      expect(guarded_edit(replace: unsafe_replace, result_custom_html_sha256: Digest::SHA256.hexdigest(raw_splice)).error).to eq(described_class::RESULT_MISMATCH_ERROR)
      expect(guarded_edit(replace: unsafe_replace, result_custom_html_sha256: Digest::SHA256.hexdigest(sanitized)).success?).to be(true)
      expect(user.reload.custom_html).to eq(sanitized)
    end

    it "matches the snippet literally where a normal edit falls back to whitespace-tolerant matching" do
      user.update!(custom_html: "<section><p><strong>Keep this instruction.</strong></p></section>")
      nbsp_page = current_page

      guarded = described_class.edit!(user, find:, replace:,
                                            expected_custom_html_sha256: Digest::SHA256.hexdigest(nbsp_page),
                                            result_custom_html_sha256: Digest::SHA256.hexdigest("<section>#{replace}</section>"))
      expect(guarded.error).to eq(described_class::FIND_MISSING_ERROR)
      expect(user.reload.custom_html).to eq(nbsp_page)

      normal = described_class.edit!(user, find:, replace:)
      expect(normal.success?).to be(true)
      expect(user.reload.custom_html).to include(replace)
    end

    it "refuses a snippet that begins at two overlapping positions, without writing" do
      user.update!(custom_html: "<div>x</div><div>x</div><div>x</div>")
      page_before = current_page
      overlapping_find = "<div>x</div><div>x</div>"
      # String#scan would report this as one occurrence, because it consumes the match at offset 0 and
      # never tries offset 11 — the splice #sub performs.
      leftmost = Ai::PageSanitizer.sanitize_with_report(page_before.sub(overlapping_find) { "<div>x</div>" }).html.to_s

      result = described_class.edit!(user, find: overlapping_find, replace: "<div>x</div>",
                                           expected_custom_html_sha256: Digest::SHA256.hexdigest(page_before),
                                           result_custom_html_sha256: Digest::SHA256.hexdigest(leftmost))

      expect(result.error).to eq(described_class.find_ambiguous_error(2))
      expect(user.reload.custom_html).to eq(page_before)
    end
  end

  describe ".check_guarded_edit" do
    it "is a pure check that reports the same errors the write would" do
      page = "<section><p>Twice</p><p>Twice</p></section>"
      digest = Digest::SHA256.hexdigest(page)

      expect(described_class.check_guarded_edit(page, find: "<p>Twice</p>", replace: "", expected_custom_html_sha256: digest, result_custom_html_sha256: "a" * 64).error)
        .to eq(described_class.find_ambiguous_error(2))
      expect(described_class.check_guarded_edit(page, find: "", replace: "", expected_custom_html_sha256: digest, result_custom_html_sha256: "a" * 64).error)
        .to eq(described_class::FIND_MISSING_ERROR)
      expect(described_class.check_guarded_edit(page, find: "<p>Twice</p><p>Twice</p>", replace: "x" * Page::MAX_CUSTOM_HTML_LENGTH, expected_custom_html_sha256: digest, result_custom_html_sha256: "a" * 64).error)
        .to eq(described_class::LENGTH_ERROR)
    end

    it "counts overlapping snippet positions as ambiguous" do
      page = "<div>x</div><div>x</div><div>x</div>"
      digest = Digest::SHA256.hexdigest(page)
      # The digest of the splice #sub would perform, so the uniqueness check is the only thing that
      # can refuse this.
      result_digest = Digest::SHA256.hexdigest("<div>x</div><div>x</div>")

      expect(described_class.check_guarded_edit(page, find: "<div>x</div><div>x</div>", replace: "<div>x</div>", expected_custom_html_sha256: digest, result_custom_html_sha256: result_digest).error)
        .to eq(described_class.find_ambiguous_error(2))
    end
  end

  describe "composing a page section by section around a marker" do
    # The store agent builds a page too big for one write by publishing a complete but minimal page
    # that carries a marker, then adding one section per reply. Both halves have to hold: the marker
    # survives the sanitizer, and one splice inserts a section ahead of it and leaves it in place.
    let(:user) { create(:user) }
    let(:shell) do
      %(<section class="store"><h1 data-gumroad-field="name">Store</h1>) +
        %(<div id="products"></div><!-- gumroad:sections --><footer>Gumroad</footer></section>)
    end

    before do
      Feature.activate_user(:custom_html_pages, user)
      user.update!(custom_html: shell)
    end

    it "keeps the marker in the stored page" do
      expect(user.reload.custom_html).to include("<!-- gumroad:sections -->")
    end

    it "inserts a section ahead of the marker and leaves exactly one marker behind" do
      section = %(<section class="about"><h2>About</h2><p>Hello</p></section>)
      result = described_class.edit!(user, find: "<!-- gumroad:sections -->", replace: "#{section}<!-- gumroad:sections -->")

      expect(result.success?).to be(true)
      page = user.reload.custom_html
      # Compare tags, not the exact string: Nokogiri re-serializes the spliced document and may add
      # whitespace between block elements.
      expect(page).to include(%(<section class="about">), "<h2>About</h2>")
      expect(page.index(%(<section class="about">))).to be < page.index("<!-- gumroad:sections -->")
      expect(page.scan("<!-- gumroad:sections -->").size).to eq(1)
    end
  end
end
