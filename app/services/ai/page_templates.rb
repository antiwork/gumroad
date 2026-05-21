# frozen_string_literal: true

module Ai
  module PageTemplates
    TEMPLATES = [
      {
        id: "minimal-product",
        name: "Minimal product",
        description: "Clean white, single product showcase, pricing card",
        icon: "digital",
        prompt: <<~PROMPT.strip,
          Design a minimal product showcase page in a clean editorial style.

          Visual style:
          - White background, generous margins, body text in zinc-700.
          - Serif heading paired with sans-serif body.
          - Calm, gallery-like spacing throughout. `py-16` between sections.

          Sections:
          - Hero: product name, single sentence positioning, one secondary line of context, and a "Buy now" CTA.
          - "What's included" section as a list with check marks.
          - One large quoted testimonial set in serif italics.
          - Single pricing card centered, with the live price and a CTA.
          - Lightweight footer with the creator's name.

          Keep it quiet, confident, and focused on the product.
        PROMPT
      },
      {
        id: "sleek-dark",
        name: "Sleek dark",
        description: "Black background, neon accents, minimal copy",
        icon: "ebook",
        prompt: <<~PROMPT.strip,
          Design a sleek, modern landing page with a dark theme.

          Visual style:
          - Pure black or near-black background (`bg-zinc-950` or `bg-black`).
          - One bright accent color (cyan, magenta, or lime) for CTAs and highlights.
          - Sans-serif typography, generous tracking on headings.
          - Heavy whitespace, big type, no stock-photo imagery.

          Sections:
          - Hero: bold one-line value prop, single CTA button, subtle gradient or grid background.
          - Three-column feature row with icon glyphs.
          - Single testimonial in a dark card with the buyer's quote, name, and role.
          - Pricing section with one card highlighted.
          - Minimal footer with social links.
        PROMPT
      },
      {
        id: "long-form-sales",
        name: "Long-form sales letter",
        description: "Narrative-driven, conversion-optimized, scrolls forever",
        icon: "newsletter",
        prompt: <<~PROMPT.strip,
          Design a long-form sales-letter style landing page focused on conversion.

          Visual style:
          - Cream/off-white background (`bg-stone-50`), dark serif headings (`font-serif`), readable sans-serif body.
          - Body text in zinc-700, max-width prose container.
          - Generous vertical rhythm — `py-16` between major sections.

          Structure (in this order):
          1. Hook headline (problem-focused), large serif, italic emphasis on the painful word.
          2. Sub-headline that twists the knife.
          3. "Dear [creator type]," opening paragraph.
          4. Story section: 3-4 paragraphs of narrative setting up the problem.
          5. "Who this is for / Who this is not for" two-column block.
          6. "Here's what you get" bullet list of 8-12 benefits (not features) with check marks.
          7. Three testimonials with first-name + role attribution (no photos required).
          8. Detailed pricing section with anchoring ("normally $X, today $Y").
          9. 30-day guarantee block, prominent.
          10. FAQ accordion (5-7 entries).
          11. Final CTA section repeating the offer and the urgency framing.

          Heavy on copy. Light on imagery. Lean into conversion-copywriting tropes.
        PROMPT
      },
      {
        id: "personal-brand",
        name: "Personal brand",
        description: "Warm, approachable, story-first creator landing",
        icon: "coffee",
        prompt: <<~PROMPT.strip,
          Design a personal-brand landing page that feels warm and human.

          Visual style:
          - Off-white background with a subtle warm tint, charcoal body text.
          - Friendly sans-serif (Inter or similar). Optional serif for the hero name.
          - Soft rounded corners (`rounded-xl`), low-contrast borders, no hard edges.

          Sections:
          - Hero: friendly headline in the creator's voice, one-paragraph intro, and CTA.
          - "About me" section with a circular avatar placeholder and short bio.
          - "What I'm offering" section presenting the product as a story rather than a SKU.
          - Single quote block from a happy buyer with first-name attribution.
          - Soft pricing block, conversational microcopy.
          - Friendly sign-off line at the bottom ("Made with care by ...").
        PROMPT
      },
      {
        id: "neobrutalist",
        name: "Neobrutalist Gumroad",
        description: "Block colors, thick borders, raw type, high contrast",
        icon: "physical",
        prompt: <<~PROMPT.strip,
          Design a neobrutalist landing page with strong Gumroad energy.

          Visual style:
          - Pure white background with one accent color (hot pink, electric blue, or lime).
          - Thick black borders (`border-2` to `border-4`) on every card, button, and image frame.
          - Hard drop shadows offset bottom-right (`shadow-[8px_8px_0px_#000]`), no blur.
          - Sans-serif typography. Big, chunky headings — `font-black`, tracking-tight, 60-90px range.
          - Buttons are square-edged rectangles with thick borders and the same hard shadow.

          Sections:
          - Hero: oversized headline, single short subhead, one CTA. Headline can break across 2-3 lines with intentional line breaks.
          - Three-column "What's in the box" block with thick-bordered cards. Each card has an emoji icon, short title, one-line description.
          - One testimonial in a hard-shadowed card.
          - Pricing block with a single highlighted card.
          - Footer: minimal, just a row of links.

          Do not soften anything — no rounded corners beyond `rounded-md`, no gradients, no soft shadows.
        PROMPT
      },
      {
        id: "design-agency",
        name: "Minimalist agency",
        description: "All black and white, generous whitespace, NY design studio",
        icon: "course",
        prompt: <<~PROMPT.strip,
          Design a landing page that feels like a minimalist New York design agency.

          Visual style:
          - Pure white background, pure black type. No accent colors.
          - Helvetica or Inter — sans-serif throughout. `font-medium` for body, `font-bold` for headings.
          - Massive whitespace. `py-32` between sections is normal.
          - Thin hairline rules (`border-t border-black`) as dividers.
          - Numbered sections (01 / 02 / 03 prefixes in monospace, small caps).
          - Left-aligned everything. No center alignment except the explicit CTA.

          Sections:
          - Hero: one-line value prop, set in a huge type (think 96-120px), left-aligned. Tiny supporting paragraph below in tracking-wide all-caps.
          - "01 — What" section: a single short paragraph and a small CTA link with an arrow.
          - "02 — Why" section: same treatment.
          - "03 — How" section: same treatment.
          - A single quote, large, set as a pull-quote.
          - Pricing as a single line of text. Not a card. Just "$X. One-time. No questions." with a CTA link.
          - Footer: address-block style with the creator name, the year, and one link.

          The whole page should feel confident, quiet, and expensive.
        PROMPT
      },
      {
        id: "art-gallery",
        name: "Art gallery",
        description: "Image-led hero, museum framing, sparse text",
        icon: "bundle",
        prompt: <<~PROMPT.strip,
          Design an art-gallery style landing page where the imagery does the talking.

          Visual style:
          - Off-white background (`bg-neutral-50`), warm-gray body text, deep-black headings.
          - Serif type throughout (`font-serif`).
          - Generous whitespace and small, museum-label-style microcopy (`text-xs uppercase tracking-widest`).
          - A single large image at the top of the page (use a placeholder `<div class="bg-neutral-300 aspect-[16/9]">`).
          - Captions under every image in italic serif, like a gallery wall label.

          Sections:
          - Top: massive hero image (16:9). Below it: artist name in small caps, then the work's title in large serif, then a one-line description in italic.
          - "About this collection" — a paragraph or two, set narrow (`max-w-prose`), readable type.
          - Gallery grid: three or four placeholder images in an asymmetric grid with captions.
          - Pricing as a single museum-label-style block at the bottom: edition number, materials, price.
          - "Acquire" CTA — small, refined, lowercase.
          - Closing block with the artist's signature line.

          The page should feel like a curated exhibition catalog, not a sales page.
        PROMPT
      },
      {
        id: "retro-90s",
        name: "Retro 90s",
        description: "Pixel fonts, gradients, sparkles, GeoCities vibe",
        icon: "audiobook",
        prompt: <<~PROMPT.strip,
          Design a retro 90s landing page that channels GeoCities, early web, and Lisa Frank energy.

          Visual style:
          - Background: tiling pattern or loud gradient (`bg-gradient-to-br from-fuchsia-400 via-yellow-300 to-cyan-400`).
          - Pixel font headings (use `font-mono` and add `text-shadow` for chunky look). Sans-serif body in cyan or magenta.
          - WordArt-style headline with rainbow gradient text (`bg-gradient-to-r from-pink-500 via-yellow-400 to-cyan-500 bg-clip-text text-transparent`).
          - Animated elements (use `animate-pulse` or `animate-bounce` for emojis).
          - Heavy emoji use: ✨💾🌟🚀.
          - "Best viewed in Netscape Navigator" footer joke.

          Sections:
          - Hero: WordArt headline, subhead with sparkles, glowing CTA button.
          - "Visitor counter" widget at the top right (just a styled span with `0042069`).
          - Three-column "Features" section with chunky icons and bouncy text.
          - Testimonial as a guestbook entry.
          - Pricing in a "BUY NOW!!!" style flashing block (use `animate-pulse`).
          - Footer with `<blink>`-style microcopy and a "Webring" row of placeholder links.

          Make it loud. Make it joyful. Make it 1997.
        PROMPT
      },
      {
        id: "limited-offer",
        name: "Limited-time offer",
        description: "Urgency banner, countdown timer, scarcity copy",
        icon: "commission",
        prompt: <<~PROMPT.strip,
          Design a limited-time offer landing page with explicit urgency and a countdown.

          Visual style:
          - White background with a sticky bright-red banner across the top: "OFFER ENDS IN [countdown]".
          - The countdown is four boxes (DAYS / HOURS / MINUTES / SECONDS) with bold numerals — render with static placeholder values and a `data-countdown-end` attribute set 14 days from today's date.
          - Black-and-red palette throughout. Bold sans-serif. Italics for urgency words.
          - Heavy use of strikethrough on old prices and red highlight on the new price.

          Sections:
          - Sticky urgency banner with countdown (top).
          - Hero: "Last chance:" prefix, then the value prop. CTA button labeled "Claim before it's gone".
          - Scarcity row: "Only N spots left" / "Price goes up at midnight" / "No second chances".
          - Three benefit cards with red checkmarks.
          - Single anchored testimonial.
          - Pricing block emphasizing the discount, with the countdown repeated below the CTA.
          - "What happens at midnight?" FAQ line at the bottom.
          - Closing CTA with the countdown one more time.

          Every section should reinforce that time is running out. Don't be subtle.
        PROMPT
      },
      {
        id: "valentines",
        name: "Valentine's day",
        description: "Pink, red, hearts, romantic copy",
        icon: "call",
        prompt: <<~PROMPT.strip,
          Design a Valentine's day themed landing page that feels like a love letter.

          Visual style:
          - Background gradient (`from-rose-50` to `to-pink-100`), soft cursive script font for the hero headline.
          - Heart accents scattered throughout (`❤️` as decoration in headers).
          - Pink and deep red accent colors, gold for emphasis.
          - Rounded corners everywhere (`rounded-2xl`), soft drop shadows.
          - Hand-drawn-feeling section dividers.

          Sections:
          - Hero: "A love letter to..." style headline, romantic positioning paragraph, CTA labeled "Be mine" or "Yours, with love".
          - "Why you'll fall for it" three-card row, each card with a heart icon.
          - One testimonial in a tilted, taped-down note card (`-rotate-1`).
          - Pricing card framed like a Valentine — heart border, red ribbon CTA.
          - Closing line: "With love, [creator name]" in cursive.

          Lean into the romance metaphor in every microcopy. This should feel warm and a little kitschy.
        PROMPT
      },
      {
        id: "membership-tiers",
        name: "Membership tiers",
        description: "Tiered pricing cards, perks comparison, recurring framing",
        icon: "membership",
        prompt: <<~PROMPT.strip,
          Design a membership landing page anchored on tiered pricing cards.

          Visual style:
          - Deep-navy background (`bg-slate-900`) with light text. Gold/amber accent (`text-amber-400`) for premium tier.
          - Sans-serif type. Headings in `font-semibold`, body in `font-light`.
          - Cards lift slightly on hover (`hover:-translate-y-1`). Premium tier card is taller and has a glowing border.

          Sections:
          - Hero: aspirational name of the membership, one-sentence promise of belonging, CTA labeled "Join now" or "Become a member".
          - Three pricing tier cards side-by-side (Bronze / Silver / Gold style, but name them the creator's brand). Middle tier highlighted as "Most popular".
          - For each tier: name, monthly price, yearly price (with savings callout), list of perks (5-8 items with checkmarks). The premium tier gets extra perks listed in amber.
          - "What members get every month" timeline (Week 1 / Week 2 / Week 3 / Week 4) — show the recurring cadence.
          - One member quote in a card with first-name + tenure ("Member since 2024").
          - FAQ with 4-5 entries focused on cancellation, billing, and access.
          - Closing CTA with member count framing ("Join 1,200+ members").

          The tiers should feel meaningfully different — not just price points. Each tier earns its price.
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
