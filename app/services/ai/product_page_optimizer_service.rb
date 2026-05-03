# frozen_string_literal: true

class Ai::ProductPageOptimizerService
  WEIGHTS = {
    name: 15,
    description: 30,
    cover: 20,
    pricing: 15,
    social_proof: 20,
  }.freeze

  CACHE_TTL = 24.hours
  CACHE_KEY_PREFIX = "product_readiness"

  ACTION_VERBS = %w[master build ship learn make grow create design launch start earn].freeze

  NAME_LENGTH_MIN = 30
  NAME_LENGTH_MAX = 60

  DESCRIPTION_WORDS_MIN = 200
  DESCRIPTION_WORDS_MAX = 800

  def initialize(product:)
    @product = product
  end

  def call
    Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { compute }
  end

  def compute
    categories = [
      score_name,
      score_description,
      score_cover,
      score_pricing,
      score_social_proof,
    ]
    overall = categories.sum { |c| c[:score] * c[:weight] }.fdiv(100).round
    {
      overall: overall,
      severity: severity_for(overall),
      categories: categories,
      computed_at: Time.current.iso8601,
    }
  end

  def cache_key
    "#{CACHE_KEY_PREFIX}:#{@product.id}:#{content_hash}"
  end

  private
    attr_reader :product

    def content_hash
      stat = product.product_review_stat
      cover_signature = product.display_asset_previews.map { |a| [a.id, a.display_type] }.sort
      parts = [
        product.name.to_s,
        product.description.to_s,
        product.price_cents.to_i,
        product.customizable_price?,
        product.display_product_reviews?,
        cover_signature,
        product.alive_variants.size,
        stat ? [stat.reviews_count.to_i, stat.average_rating.to_f.round(2)] : [0, 0.0],
      ]
      Digest::SHA256.hexdigest(parts.to_json)[0, 16]
    end

    def severity_for(score)
      return "good" if score >= 80
      return "ok" if score >= 60
      return "weak" if score >= 40
      "missing"
    end

    def clamp(n, lo, hi)
      [[n, lo].max, hi].min
    end

    def score_name
      name = product.name.to_s.strip
      length = name.length
      details = []

      if length.zero?
        return category(:name, 0, "missing", "Empty", ["No name set"])
      end

      score = 0
      if length >= NAME_LENGTH_MIN && length <= NAME_LENGTH_MAX
        score += 60
        details << "Length #{length} chars — in sweet spot"
      elsif length < NAME_LENGTH_MIN
        score += ((length.to_f / NAME_LENGTH_MIN) * 50).round
        details << "Length #{length} chars — short, target #{NAME_LENGTH_MIN}-#{NAME_LENGTH_MAX}"
      else
        score += clamp(70 - (length - NAME_LENGTH_MAX), 25, 60)
        details << "Length #{length} chars — long, target #{NAME_LENGTH_MIN}-#{NAME_LENGTH_MAX}"
      end

      if name.match?(/\d/)
        score += 15
        details << "Contains a number"
      end

      lower = name.downcase
      if ACTION_VERBS.any? { |v| lower.include?(v) }
        score += 25
        details << "Contains action verb"
      end

      score = clamp(score, 0, 100)
      note = if score >= 80 then "Clear and specific"
      elsif score >= 60 then "Decent"
      else "Vague — add specificity"
      end
      category(:name, score, severity_for(score), note, details)
    end

    def score_description
      html = product.description.to_s
      text = strip_html(html)
      words = word_count(text)
      details = []

      if words.zero?
        return category(:description, 0, "missing", "Empty", ["No description set"])
      end

      score = 0
      if words >= DESCRIPTION_WORDS_MIN && words <= DESCRIPTION_WORDS_MAX
        score += 50
        details << "#{words} words — in sweet spot"
      elsif words < DESCRIPTION_WORDS_MIN
        score += ((words.to_f / DESCRIPTION_WORDS_MIN) * 40).round
        details << "#{words} words — too short, target #{DESCRIPTION_WORDS_MIN}-#{DESCRIPTION_WORDS_MAX}"
      else
        score += clamp(60 - ((words - DESCRIPTION_WORDS_MAX) / 50), 20, 50)
        details << "#{words} words — too long, target #{DESCRIPTION_WORDS_MIN}-#{DESCRIPTION_WORDS_MAX}"
      end

      if html.match?(/<(ul|ol)\b/i)
        score += 15
        details << "Has bullet list"
      else
        details << "No bullet list (lose 15 pts)"
      end

      if html.match?(/<h[1-6]\b/i)
        score += 10
        details << "Has headings"
      end

      if text.match?(/\d/)
        score += 10
        details << "Contains specific numbers"
      else
        details << "No concrete numbers (lose 10 pts)"
      end

      if text.match?(/\bfor\s+\w+\s+who\b/i)
        score += 10
        details << "Has audience-of-one phrasing"
      end

      if text.match?(/\bfaq\b|\bfrequently asked\b|\bquestions\b/i)
        score += 10
        details << "Includes FAQ section"
      end

      score = clamp(score, 0, 100)
      note = if score >= 80 then "Concrete and structured"
      elsif score >= 60 then "Decent — could be more specific"
      else "Lacks structure or specifics"
      end
      category(:description, score, severity_for(score), note, details)
    end

    def score_cover
      covers = product.display_asset_previews.to_a
      details = []

      if covers.empty?
        return category(:cover, 0, "missing", "No cover uploaded",
                        ["No cover image — biggest single conversion lever"])
      end

      score = 60
      details << "#{covers.length} cover#{covers.length > 1 ? "s" : ""} uploaded"

      if covers.length >= 2
        score += 20
        details << "Multiple covers — gallery"
      end

      has_video = covers.any? { |c| %w[video oembed].include?(c.display_type) }
      if has_video
        score += 20
        details << "Includes video preview"
      else
        details << "No video preview (lose 20 pts)"
      end

      score = clamp(score, 0, 100)
      note = if score >= 80 then "Strong visuals"
      elsif score >= 60 then "Decent"
      else "Could be brighter or include video"
      end
      category(:cover, score, severity_for(score), note, details)
    end

    def score_pricing
      cents = product.price_cents.to_i
      customizable = product.customizable_price?
      details = []

      if cents <= 0 && !customizable
        return category(:pricing, 20, "weak", "Free — leaves money on the table",
                        ["Consider a paid tier or PWYW with floor"])
      end

      score = 70
      details << "$#{format("%.2f", cents / 100.0)} base price"

      variants_count = product.alive_variants.size
      if variants_count >= 2
        score += 15
        details << "#{variants_count} variants — tiered"
      else
        details << "Single tier (lose 15 pts) — consider variants"
      end

      if charm_priced?(cents)
        score += 15
        details << "Charm pricing applied"
      else
        details << "No charm pricing (lose 15 pts) — try $X.99 or $X.97"
      end

      score = clamp(score, 0, 100)
      note = if score >= 80 then "Strong tiered pricing"
      elsif score >= 60 then "Decent"
      else "Try variants or charm pricing"
      end
      category(:pricing, score, severity_for(score), note, details)
    end

    def score_social_proof
      stat = product.product_review_stat
      count = stat&.reviews_count.to_i
      avg = stat&.average_rating.to_f
      details = []

      if count.zero?
        return category(:social_proof, 0, "missing", "No reviews yet",
                        ["Email recent buyers asking for reviews"])
      end

      count_score = clamp(((Math.log10([1, count].max) / Math.log10(50)) * 70).round, 0, 70)
      score = count_score
      details << "#{count} review#{count > 1 ? "s" : ""} (#{count_score} pts)"

      if avg >= 4.5
        score += 30
        details << "#{format("%.1f", avg)} avg — excellent"
      elsif avg >= 4.0
        score += 22
        details << "#{format("%.1f", avg)} avg — strong"
      elsif avg >= 3.0
        score += 10
        details << "#{format("%.1f", avg)} avg — middling"
      else
        details << "#{format("%.1f", avg)} avg — concerning"
      end

      unless product.display_product_reviews?
        score = (score * 0.7).round
        details << "Reviews hidden on product page (-30%)"
      end

      score = clamp(score, 0, 100)
      note = if count >= 10 && avg >= 4 then "Solid social proof"
      elsif count.positive? then "Surface what you have"
      else "No reviews yet"
      end
      category(:social_proof, score, severity_for(score), note, details)
    end

    def category(key, score, severity, note, details)
      {
        key: key.to_s,
        label: key.to_s.titleize,
        weight: WEIGHTS.fetch(key),
        score: score,
        severity: severity,
        note: note,
        details: details,
      }
    end

    def strip_html(html)
      html.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
    end

    def word_count(text)
      return 0 if text.empty?
      text.split(/\s+/).length
    end

    def charm_priced?(cents)
      return false if cents <= 0
      remainder = cents % 100
      return true if remainder == 99 || remainder == 97
      remainder.zero? && (cents / 100) % 10 == 9
    end
end
