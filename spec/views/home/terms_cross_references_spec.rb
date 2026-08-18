# frozen_string_literal: true

require "spec_helper"

# Asserts the Terms document is internally consistent rather than pinning a list of expected
# numbers, so a legitimate Terms edit does not have to rewrite this file. gumroad-private#1617.
#
# Ruby's \s does not match U+00A0 and this file's hand-maintained markup gaps mix both, so a \s gap
# silently skips the nbsp-gapped rows: with \s the heading scans find 2 sections and 83 subsections
# instead of 27 and 84. POSIX [[:space:]] matches both.
describe "app/views/home/terms.html.erb cross-references" do
  # Methods rather than constants: a constant assigned in a describe block lands on Object and
  # collides with the next spec that picks the same name.
  def sp
    "[[:space:]]"
  end

  # Connectives drift between a heading and the citations of it ("Class and Other" vs "Class or
  # Other") while naming the same clause, and so do hyphens ("Non-Individualized" vs
  # "NonIndividualized"). Dropping both keeps this spec about NUMBERS pointing at the right place,
  # which is the defect class, rather than about copy-editing.
  def title_key(text)
    text.downcase.gsub(/\b(?:and|or|the|of|a)\b/, "").gsub(/[^a-z0-9]/, "")
  end

  def normalize(text)
    text.gsub(/#{sp}+/o, " ").strip.delete_suffix(".")
  end

  let(:source) { Rails.root.join("app/views/home/terms.html.erb").read }

  # "8.1  Purchasing Process." => { "8.1" => "Purchasing Process" }
  let(:subsections) do
    source.scan(/<strong>#{sp}*(\d{1,2})\.(\d{1,2})#{sp}+([^<]*?)\.?#{sp}*<\/strong>/o)
          .to_h { |maj, min, title| ["#{maj}.#{min}", normalize(title)] }
  end

  # "5.  THIRD-PARTY PAYMENTS PROVIDERS." => { 5 => "THIRD-PARTY PAYMENTS PROVIDERS" }
  let(:sections) do
    source.scan(/<strong>#{sp}*(\d{1,2})\.#{sp}+([A-Z][^<]*?)\.?#{sp}*<\/strong>/o)
          .each_with_object({}) { |(n, title), h| h[n.to_i] ||= normalize(title) }
  end

  # "Section", "section", "SECTION", singular or plural. The caps form is not decoration: the
  # emphasised passages cite SECTION 18 (RELEASE), SECTION 25 (ARBITRATION AGREEMENT) and six
  # others, and a scan that only saw title case left all of them unchecked.
  #
  # (?!\d) keeps a 1-2 digit number from matching inside a longer one, which is what stops
  # "CALIFORNIA CIVIL CODE SECTION 1542" — a statute, not a cite — from reading as section 15.
  #
  # No /o on either: these interpolate the caller's pattern, and /o would cache the first call's
  # pattern and silently reuse it for the second.
  def section_word
    "[Ss]ections?|SECTIONS?"
  end

  # Titled cites, as [cited number, cited title]. A comma before the paren is drift, not a
  # different construct ("Section 25.4, (Waiver...)"), so it is tolerated.
  def titled_cites(pattern)
    source.scan(/(?:#{section_word})#{sp}+(#{pattern})(?!\d)(?!\.\d),?#{sp}*\(([^)]{3,90})\)/)
  end

  # Every number a cite points at, titled or not, in any of the forms this document uses: lowercase
  # "section 6.4", plural "Sections 11.3(a) and 11.3(b)", letter limbs "Section 11.3(c)". A limb
  # cite resolves to its parent subsection, which is what has a heading.
  #
  # Two passes, because one "Sections" prefix can govern a list: the prefix pass finds the head of
  # each cite, then the list pass walks the "and"/"," continuations after it. Matching only after
  # the prefix would capture 11.3 out of "Sections 11.3(a) and 11.99(b)" and let the bad
  # continuation through — the shape §11.3(c) actually uses.
  #
  # The separator takes a comma AND a trailing conjunction in one step. Alternating them instead
  # ("," or " and") stops at an Oxford comma: the comma matches, then a number is required where
  # "and" sits, so the last item of "Sections 4.1, 9.98, and 9.99" never reaches the existence check.
  def cited_numbers(pattern)
    numbers = source.scan(/(?:#{section_word})#{sp}+((?:#{pattern})(?!\d)(?!\.\d)(?:\([a-z0-9]\))?
                          (?:(?:,#{sp}*(?:and|or)?|#{sp}+(?:and|or))?#{sp}+(?:#{pattern})(?!\d)(?!\.\d)(?:\([a-z0-9]\))?)*)/x)
    numbers.flatten
           .flat_map { |run| run.scan(/#{pattern}/) }
           .uniq
  end

  # A cite is dead when the number it names does not exist, or when the number it names is titled
  # something else — which is exactly what §8.1's "Section 1 (Third-Party Payments Providers)" was
  # against section 5. Compared against the CITED number's own heading rather than by searching for
  # whichever number owns the title: sections 2 and 17 share the heading "INTERACTIONS WITH OTHER
  # USERS", so a title search cannot tell those two apart, and a title matching no heading at all
  # would drop out of the check entirely.
  def dead_cites(cites, headings)
    cites.filter_map do |num, raw_title|
      title = normalize(raw_title)
      key = headings.keys.first.is_a?(Integer) ? num.to_i : num
      heading = headings[key]

      next "'Section #{num} (#{title})' — there is no Section #{num}" if heading.nil?
      # Prefix, not equality: a cite may shorten its target's heading ("SECTION 20 (DISCLAIMER OF
      # WARRANTIES)" for "DISCLAIMER OF WARRANTIES AND CONDITIONS"), and §25's heading runs on into
      # a paragraph of prose. A wrong number still fails — no other heading starts with the cited
      # title.
      next if title_key(heading).start_with?(title_key(title))

      "'Section #{num} (#{title})' — Section #{num} is '#{heading}'"
    end
  end

  it "parses the document it is asserting about" do
    expect(sections.keys.sort).to eq((1..27).to_a)

    # Per section rather than one total: "expected 84, got 83" does not say which heading stopped
    # parsing, and if the lost one is the last of its section the contiguity example stays green too.
    counts = subsections.keys.group_by { |k| k.split(".").first.to_i }.transform_values(&:size)
    expect(counts.sort.to_h).to eq(
      { 1 => 2, 3 => 4, 4 => 5, 6 => 9, 8 => 2, 10 => 8, 11 => 4, 12 => 2, 13 => 6, 16 => 2,
        17 => 3, 20 => 2, 21 => 4, 23 => 4, 25 => 12, 26 => 2, 27 => 14 }
    )
  end

  it "resolves every titled whole-section cite to the section it names" do
    cites = titled_cites('\d{1,2}')
    expect(cites.size).to eq(13)

    dead = dead_cites(cites, sections)
    expect(dead).to be_empty, dead.join("\n")
  end

  it "resolves every titled subsection cite to the subsection it names" do
    cites = titled_cites('\d{1,2}\.\d{1,2}')
    expect(cites.size).to eq(17)

    dead = dead_cites(cites, subsections)
    expect(dead).to be_empty, dead.join("\n")
  end

  it "points every subsection cite at a subsection that exists" do
    cited = cited_numbers('\d{1,2}\.\d{1,2}')
    expect(cited.sort).to eq(["10.5", "11.3", "11.4", "12.1", "25.1", "25.4", "25.5", "25.9", "3.4", "4.1", "6.1", "6.4"])

    missing = cited - subsections.keys
    expect(missing).to be_empty, "cited but absent: #{missing.inspect}"
  end

  it "points every whole-section cite at a section that exists" do
    cited = cited_numbers('\d{1,2}').map(&:to_i)
    expect(cited.sort).to eq([5, 6, 7, 14, 18, 19, 20, 25])

    missing = cited - sections.keys
    expect(missing).to be_empty, "cited but absent: #{missing.inspect}"
  end

  # The scans above only protect the document if they read a whole list, not just its head. §11.3(c)
  # cites "Sections 11.3(a) and 11.3(b)", so a continuation is a real shape here rather than a
  # hypothetical one, and a dead number in the tail position must not slip through.
  it "reads every number in a list governed by one Sections prefix" do
    document = instance_double(Pathname, read: <<~HTML)
      <p>In addition to and without limiting Sections 11.3(a) and 11.99(b), Gumroad may act.</p>
      <p>Nothing in Sections 4.1, 9.98 or 9.99 limits Sections 14 and 40.</p>
    HTML
    allow(Rails.root).to receive(:join).with("app/views/home/terms.html.erb").and_return(document)

    expect(cited_numbers('\d{1,2}\.\d{1,2}')).to contain_exactly("11.3", "11.99", "4.1", "9.98", "9.99")
    expect(cited_numbers('\d{1,2}').map(&:to_i)).to include(14, 40)
  end

  # Separate from the list example above because the Oxford comma is where a list scan is most
  # likely to stop one item early: the comma and the conjunction are both present, and a separator
  # that takes one or the other consumes the comma and then demands a number where "and" is. The
  # tail is the position a dead cite hides in, so the last number has to be read.
  it "reads the last number of a list written with an Oxford comma" do
    document = instance_double(Pathname, read: <<~HTML)
      <p>Nothing in Sections 4.1, 9.98, and 9.99 limits Sections 14, 19, or 40.</p>
    HTML
    allow(Rails.root).to receive(:join).with("app/views/home/terms.html.erb").and_return(document)

    expect(cited_numbers('\d{1,2}\.\d{1,2}')).to contain_exactly("4.1", "9.98", "9.99")
    expect(cited_numbers('\d{1,2}').map(&:to_i)).to include(14, 19, 40)
  end

  # The (?!\d) guard above is what keeps "CALIFORNIA CIVIL CODE SECTION 1542" from reading as a
  # cite to section 15. Asserted rather than trusted: widening the number pattern later would
  # silently pull a statute into the cite set and fail as "there is no Section 1542".
  it "reads the California Civil Code reference as a statute, not a cross-reference" do
    expect(source).to match(/SECTION#{sp}+1542/o)
    expect(cited_numbers('\d{1,2}').map(&:to_i)).not_to include(15)
    expect(titled_cites('\d{1,4}').map(&:first)).not_to include("1542")
  end

  it "numbers each subsection under the section it is printed beneath" do
    order = source.scan(/<strong>#{sp}*(\d{1,2})\.(\d{1,2})?#{sp}+[^<]*?<\/strong>/o)
    expect(order.count { |_, min| min.nil? }).to eq(sections.size)

    current = nil
    misplaced = order.each_with_object([]) do |(maj, min), acc|
      if min.nil?
        current = maj.to_i
      elsif maj.to_i != current
        acc << "#{maj}.#{min} appears under section #{current.inspect}"
      end
    end
    expect(misplaced).to be_empty, misplaced.join("\n")
  end

  it "numbers subsections contiguously from 1 with no number used twice" do
    grouped = subsections.keys.group_by { |k| k.split(".").first.to_i }
                         .transform_values { |ks| ks.map { |k| k.split(".").last.to_i } }
    broken = grouped.reject { |_, mins| mins == (1..mins.size).to_a }
    expect(broken).to be_empty, broken.map { |sec, mins| "section #{sec}: #{mins.inspect}" }.join("\n")
  end

  # The help center cites Terms section numbers in prose and deep-links one of them, so a renumber
  # can strand a live article. These are the only such references in the repo.
  it "keeps the section numbers the help center cites" do
    expect(source).to include('id="section-11-3"')
    expect(subsections["11.3"]).to match(/Holds on Funds/)
    expect(source).to include('id="section-11-4"')
    expect(subsections["11.4"]).to match(/Changing Payout Country/)
    expect(sections[22]).to match(/COPYRIGHT INFRINGEMENT/)

    articles = Rails.root.glob("app/views/help_center/articles/contents/*.html.erb")
                    .to_h { |path| [path.basename.to_s, path.read] }

    suspension = articles.fetch("_160-suspension.html.erb")
    expect(suspension).to include("gumroad.com/terms#section-11-3")
    expect(suspension).to match(/Section#{sp}+11\.3/o)
    expect(articles.fetch("_155-things-you-cant-sell-on-gumroad.html.erb")).to match(/section#{sp}+11\.3/o)
    expect(articles.fetch("_13-getting-paid.html.erb")).to include("gumroad.com/terms#section-11-4")
    expect(articles.fetch("_260-your-payout-settings-page.html.erb")).to include("gumroad.com/terms#section-11-4")
    expect(articles.fetch("_286-how-do-i-report-a-gumroad-creator.html.erb")).to match(/Section#{sp}+22#{sp}+of/o)

    # Same section-word alternation as the Terms scans, so a new article citing "SECTIONS 11.3 and
    # 22" is not silently absent from the set below. (?!\d) so "17 U.S.C. Section 512" in the DMCA
    # article is not read as Terms section 51.
    cited = articles.values
                    .flat_map { |body| body.scan(/(?:#{section_word})#{sp}+(\d{1,2}(?:\.\d{1,2})?)(?!\d)/) }
                    .flatten.uniq
    expect(cited.sort).to eq(["11.3", "11.4", "22"]),
                          "help articles cite Terms sections #{cited.sort.inspect}. A number new to " \
                          "this list needs asserting above against the heading it points at."
  end
end
