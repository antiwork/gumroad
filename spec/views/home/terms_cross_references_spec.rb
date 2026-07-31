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

  # Titled cites, as [cited number, cited title]. A comma before the paren is drift, not a
  # different construct ("Section 25.4, (Waiver...)"), so it is tolerated.
  # No /o here: these regexes interpolate the caller's pattern, and /o would cache the first
  # call's pattern and silently reuse it for the second.
  def titled_cites(pattern)
    source.scan(/[Ss]ections?#{sp}+(#{pattern})(?!\d)(?!\.\d),?#{sp}*\(([^)]{3,90})\)/)
  end

  # Every number a cite points at, titled or not, in any of the forms this document uses: lowercase
  # "section 6.4", plural "Sections 11.3(a) and 11.3(b)", letter limbs "Section 11.3(c)". A limb
  # cite resolves to its parent subsection, which is what has a heading.
  def cited_numbers(pattern)
    source.scan(/[Ss]ections?#{sp}+(#{pattern})(?!\d)(?!\.\d)(?:\([a-z0-9]\))?/).flatten.uniq
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
      next if title_key(heading) == title_key(title)

      "'Section #{num} (#{title})' — Section #{num} is '#{heading}'"
    end
  end

  it "parses the document it is asserting about" do
    expect(sections.keys.sort).to eq((1..27).to_a)
    expect(subsections.keys.size).to eq(84)
  end

  it "resolves every titled whole-section cite to the section it names" do
    cites = titled_cites('\d{1,2}')
    expect(cites.size).to eq(6)

    dead = dead_cites(cites, sections)
    expect(dead).to be_empty, dead.join("\n")
  end

  it "resolves every titled subsection cite to the subsection it names" do
    cites = titled_cites('\d{1,2}\.\d{1,2}')
    expect(cites.size).to eq(15)

    dead = dead_cites(cites, subsections)
    expect(dead).to be_empty, dead.join("\n")
  end

  it "points every subsection cite at a subsection that exists" do
    cited = cited_numbers('\d{1,2}\.\d{1,2}')
    expect(cited.size).to eq(10)

    missing = cited - subsections.keys
    expect(missing).to be_empty, "cited but absent: #{missing.inspect}"
  end

  it "points every whole-section cite at a section that exists" do
    cited = cited_numbers('\d{1,2}').map(&:to_i)
    expect(cited.sort).to eq([5, 6, 7, 14, 20])

    missing = cited - sections.keys
    expect(missing).to be_empty, "cited but absent: #{missing.inspect}"
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
    expect(sections[22]).to match(/COPYRIGHT INFRINGEMENT/)

    articles = Rails.root.glob("app/views/help_center/articles/contents/*.html.erb")
                    .to_h { |path| [path.basename.to_s, path.read] }

    suspension = articles.fetch("_160-suspension.html.erb")
    expect(suspension).to include("gumroad.com/terms#section-11-3")
    expect(suspension).to match(/Section#{sp}+11\.3/o)
    expect(articles.fetch("_155-things-you-cant-sell-on-gumroad.html.erb")).to match(/section#{sp}+11\.3/o)
    expect(articles.fetch("_286-how-do-i-report-a-gumroad-creator.html.erb")).to match(/Section#{sp}+22#{sp}+of/o)

    # (?!\d) so "17 U.S.C. Section 512" in the DMCA article is not read as Terms section 51.
    cited = articles.values
                    .flat_map { |body| body.scan(/[Ss]ection#{sp}+(\d{1,2}(?:\.\d{1,2})?)(?!\d)/o) }
                    .flatten.uniq
    expect(cited.sort).to eq(["11.3", "22"])
  end
end
