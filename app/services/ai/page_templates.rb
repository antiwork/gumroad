# frozen_string_literal: true

module Ai
  module PageTemplates
    TEMPLATES = [
      {
        id: "sleek-dark",
        name: "Sleek dark",
        description: "Black background, neon accents, minimal copy",
        icon: "moon",
        prompt: <<~PROMPT.strip,
          Design a sleek, modern landing page with a dark theme.
          - Pure black or near-black background (bg-zinc-950 or bg-black).
          - One bright accent color (cyan, magenta, or lime) for CTAs and highlights.
          - Sans-serif typography, generous tracking on headings.
          - Hero: bold one-line value prop, single CTA button, subtle gradient or grid background.
          - Three-column feature row with icon glyphs.
          - Single testimonial in a dark card with the buyer's quote, name, and role.
          - Pricing section with one card highlighted.
          - Minimal footer with social links.
          Use heavy whitespace, big type, no stock-photo imagery.
        PROMPT
      },
      {
        id: "minimal-product",
        name: "Minimal product",
        description: "Clean white, single product showcase, pricing card",
        icon: "box",
        prompt: <<~PROMPT.strip,
          Design a minimal product showcase page in a clean editorial style.
          - White background, generous margins, body text in zinc-700.
          - Serif heading paired with sans-serif body (Inter + Newsreader vibe).
          - Hero: product name, single sentence positioning, one secondary line of context, and a "Buy now" CTA.
          - "What's included" section as a list with checkmarks.
          - One large quoted testimonial set in serif italics.
          - Single pricing card centered, with the live price and a CTA.
          - Calm, gallery-like spacing throughout.
        PROMPT
      },
      {
        id: "long-form-sales",
        name: "Long-form sales",
        description: "Conversion-optimized sales letter with pain/agitate/solve",
        icon: "trending-up",
        prompt: <<~PROMPT.strip,
          Design a long-form sales-letter style landing page optimized for conversions.
          - Cream / off-white background, dark serif type for headings, readable line lengths.
          - Hook headline (problem-focused), then subheadline that twists the knife.
          - "Who this is for" / "Who this is not for" two-column block.
          - Bullet list of benefits (not features), 8-12 items with icons.
          - Three testimonial cards with photos as initials avatars.
          - Detailed pricing section with a guarantee.
          - FAQ accordion with 5-7 entries.
          - Final CTA section repeating the headline and the offer.
        PROMPT
      },
      {
        id: "creator-personal",
        name: "Personal brand",
        description: "Warm, approachable, story-first creator landing",
        icon: "user",
        prompt: <<~PROMPT.strip,
          Design a personal-brand landing page that feels warm and human.
          - Off-white background with subtle warm tint, charcoal body text.
          - Hero: friendly headline in the creator's voice, one-paragraph intro, and CTA.
          - "About me" section with a circular avatar placeholder and short bio.
          - "What I'm offering" section presenting the product as a story rather than a SKU.
          - Single quote block from a happy buyer with first-name attribution.
          - Soft pricing block, conversational microcopy.
          - Friendly sign-off line at the bottom ("Made with care by ...").
        PROMPT
      },
      {
        id: "course-launch",
        name: "Course launch",
        description: "Curriculum-first layout for cohort/digital course",
        icon: "book-open",
        prompt: <<~PROMPT.strip,
          Design a course-launch landing page that prioritizes curriculum and outcomes.
          - White background, indigo accent color, sans-serif throughout.
          - Hero: course name, outcome-driven subheadline, primary CTA + cohort start date placeholder.
          - "What you'll learn" bullets in two columns.
          - Curriculum section as an ordered list of modules with one-line descriptions.
          - Instructor block with placeholder bio, credentials, social links.
          - Pricing tiers: 2-3 cards (single-payment vs. installments) with one highlighted.
          - FAQ with 4 entries.
          - Closing CTA with urgency framing.
        PROMPT
      },
      {
        id: "membership-club",
        name: "Membership / club",
        description: "Recurring community framing, perks list, member feel",
        icon: "users",
        prompt: <<~PROMPT.strip,
          Design a membership/club landing page focused on belonging and recurring value.
          - Deep navy or forest-green background, gold or warm-cream accent.
          - Hero: aspirational name of the membership, one-sentence promise, primary CTA.
          - "What members get" grid (6 perks) with icons.
          - "Members get this monthly" recurring-cadence timeline (Week 1 / 2 / 3 / 4).
          - One member quote in a card.
          - Pricing block emphasizing monthly + yearly options, yearly highlighted as best value.
          - Final CTA with member count or community-size framing.
        PROMPT
      }
    ].freeze

    def self.find(id)
      TEMPLATES.find { |t| t[:id] == id }
    end

    def self.prompt_for(id)
      find(id)&.dig(:prompt)
    end

    def self.public_list
      TEMPLATES.map { |t| t.slice(:id, :name, :description, :icon) }
    end
  end
end
