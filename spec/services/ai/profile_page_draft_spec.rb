# frozen_string_literal: true

require "spec_helper"

describe Ai::ProfilePageDraft do
  let(:seller) { create(:user) }
  let(:conversation) { create(:ai_conversation, seller:) }
  let(:draft) { described_class.new(seller:, conversation:) }

  after { $redis.del(RedisKey.profile_page_draft(seller.id, conversation.id)) }

  it "seeds catalogue sections without embedding a product list" do
    draft.seed_catalogue!
    html = draft.compose

    expect(html).to include('data-gumroad-field="name"')
    expect(html).to include('data-gumroad-field="bio"')
    expect(html).to include('data-profile-grid="products"')
    expect(html).to include('data-profile-grid="posts"')
    expect(html).to include("products_total")
    expect(html).to include("posts_total")
    expect(html).to include("gumroadProducts")
    expect(html).not_to include(seller.name.to_s) if seller.name.present?
  end

  it "replaces a catalogue section instead of duplicating it" do
    draft.append(kind: "products", heading: "Shop")
    draft.append(kind: "products", heading: "Catalogue")

    expect(draft.section_count).to eq(1)
    expect(draft.compose).to include("Catalogue")
    expect(draft.compose).not_to include(">Shop<")
  end

  it "rejects a custom section that cannot fit in one reply" do
    result = draft.append(kind: "html", label: "Start Here", html: "a" * (described_class::MAX_SECTION_HTML + 1))

    expect(result.error).to include("Split it")
    expect(draft).to be_empty
  end

  it "keeps a custom section and tells the creator nothing is published" do
    result = draft.append(kind: "html", label: "Start Here", html: "<section><h2>Start Here</h2><p>Welcome</p></section>")

    expect(result.error).to be_nil
    expect(result.tell_the_creator).to include("Start Here")
    expect(result.tell_the_creator).to include("Nothing is published")
    expect(draft.compose).to include("Welcome")
  end

  it "does not let one seller's draft leak into another conversation" do
    other_conversation = create(:ai_conversation, seller:)
    other = described_class.new(seller:, conversation: other_conversation)
    draft.append(kind: "name_bio")

    expect(other).to be_empty
  ensure
    $redis.del(RedisKey.profile_page_draft(seller.id, other_conversation.id))
  end
end
