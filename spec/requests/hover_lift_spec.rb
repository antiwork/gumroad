# frozen_string_literal: true

require "spec_helper"

describe "Hover lift under the pointer", type: :system, js: true do
  let(:lift_settle_seconds) { 0.5 }
  let(:nudge_seconds) { 0.2 }
  let(:nudge_count) { 6 }

  def rect(element) = element.evaluate_script("this.getBoundingClientRect().toJSON()").transform_keys(&:to_sym)
  def move_pointer_to(x, y) = page.driver.browser.action.move_to_location(x, y).perform

  # 1px inside the resting bottom edge, which a lift up and to the left moves away from.
  def rest_on_bottom_edge(element)
    scroll_to(element, align: :center)
    move_pointer_to(0, 0)
    sleep lift_settle_seconds
    resting = rect(element)
    point = [((resting[:left] + resting[:right]) / 2).floor, (resting[:bottom] - 1).floor]
    move_pointer_to(*point)
    sleep lift_settle_seconds
    point
  end

  def hover_leaves_while_nudging(element)
    x, y = rest_on_bottom_edge(element)
    element.execute_script("this.hoverLeaves = 0; this.addEventListener('mouseleave', () => this.hoverLeaves++)")
    nudge_count.times do |nudge|
      move_pointer_to(x + (nudge.even? ? 1 : 0), y)
      sleep nudge_seconds
    end
    element.evaluate_script("this.hoverLeaves")
  end

  describe "a product's version options" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:category) { create(:variant_category, link: product, title: "Size") }

    before do
      create(:variant, variant_category: category, name: "Small")
      create(:variant, variant_category: category, name: "Large")
    end

    it "keeps an option hovered and selectable on its bottom edge when the store turns the button lift off" do
      seller.seller_profile.update!(button_hover: "none")
      visit product.long_url
      option = find("[role=radio][aria-label='Large']")

      expect(hover_leaves_while_nudging(option)).to eq(0)
      expect(option.evaluate_script("this.matches(':hover')")).to eq(true)
      page.driver.browser.action.click.perform

      expect(page).to have_selector("[role=radio][aria-label='Large'][aria-checked=true]")
    end
  end

  describe "a blog post card" do
    let(:blog_owner) { create(:user, username: "gumroad") }
    let!(:blog_post) { create(:audience_post, :published, seller: blog_owner, shown_on_profile: true, published_at: 2.days.ago, name: "Older post") }

    before { create(:audience_post, :published, seller: blog_owner, shown_on_profile: true, published_at: 1.day.ago, name: "Newer post") }

    it "opens the post from a click on the card's bottom edge" do
      visit gumroad_blog_root_path
      card = find("article a[href='#{gumroad_blog_post_path(blog_post.slug)}']")

      rest_on_bottom_edge(card)
      page.driver.browser.action.click.perform

      expect(page).to have_current_path(gumroad_blog_post_path(blog_post.slug))
    end
  end
end
