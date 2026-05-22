# frozen_string_literal: true

module Ai
  module PageTemplates
    TEMPLATES = [
      # === Reframe the medium ===
      {
        id: "album-not-store",
        name: "Album, not a store",
        description: "Treat the page like a record release — tracklist, sleeve notes, credits",
        icon: "audio",
        prompt: <<~PROMPT.strip,
          Treat this like an album release, not a product page. The visitor is a fan flipping through a record on release day, not a shopper comparing SKUs.

          Visual style:
          - Deep matte black background with a single warm spot-color accent (`bg-amber-500` or `bg-rose-500`).
          - One large square "album cover" image at the top (16:16 aspect, use a placeholder div if no image).
          - Heavy use of monospaced type (`font-mono`) for tracklist and credits; sans-serif for body.
          - Generous letter-spacing on the title (`tracking-widest`), uppercase small caps for section labels.

          Sections:
          - Hero: square album-cover panel on the left, the work's title + creator name in the style of a record sleeve on the right. A small "Side A — Now playing" label above the title.
          - Tracklist: numbered list of what's inside, in monospace, with runtime-style metadata (`02:34 — Chapter title`).
          - "Liner notes": one paragraph of personal context from the creator.
          - "Credits" block at the bottom, set in 3 columns: produced by, recorded at, thanks to.
          - Single CTA labeled "Get the record" in the accent color.

          The page should feel like an artefact you'd display, not an item you'd add to a cart.
        PROMPT
      },
      {
        id: "zine",
        name: "Build it as a zine",
        description: "Photocopied, hand-cut, stapled-corner DIY publication",
        icon: "newsletter",
        prompt: <<~PROMPT.strip,
          Build this like a photocopied zine — hand-cut, taped, glued, stapled in the corner. Imperfection is the point.

          Visual style:
          - Off-white paper background (`bg-stone-100`) with subtle noise. Ink-black type (`text-zinc-900`).
          - Mixed fonts on purpose: `font-mono` for headers, hand-drawn-feeling serif for body (`font-serif italic`).
          - Rotated section blocks (`-rotate-1`, `rotate-2`) like pages were laid out crooked under a copier.
          - Heavy black dividers, hand-drawn underlines (use `border-b-4 border-black`), occasional `bg-black text-white` inverted blocks.
          - Tape and staple visual marks (use small `bg-yellow-300 rotate-12` rectangles as fake masking tape).

          Sections:
          - Cover: oversized title set in mixed type sizes within a single block (think headline cut from a magazine), date stamp in the corner, "Issue #01" label.
          - "From the editor" — one column of body copy with hard-justified text.
          - "Inside this issue" — a table of contents with page numbers, set monospace.
          - "Article": the product/work positioned as a story, with a pull-quote in the margin.
          - Classifieds-style block at the bottom listing 3 small offers/links.
          - A CTA cut out and pasted in: "Buy this issue" in a slightly tilted black box.

          Embrace asymmetry and slight ugliness. This is not Squarespace.
        PROMPT
      },
      {
        id: "mixtape-cover",
        name: "Mixtape cover, not a product page",
        description: "Cassette J-card aesthetic, hand-written tracklist, faded photo",
        icon: "audio",
        prompt: <<~PROMPT.strip,
          Render this like a cassette mixtape J-card. The visitor should feel handed a tape with a name scribbled on the spine.

          Visual style:
          - Faded sepia or washed-pastel background (`bg-stone-200`, `bg-rose-100`).
          - Cursive script font for the mixtape title (use a `font-serif italic` with weight + tracking tweaks).
          - Permanent-marker-feel handwriting for tracklist (use `font-mono` and tilt slightly `-rotate-1`).
          - A horizontal "cassette" graphic across the top — a long rectangular div with two darker circles inside for tape reels.
          - Slight grain, slight skew. Imperfect alignment.

          Sections:
          - Header: a faked J-card with "Side A" / "Side B" labels and the mixtape title in script across the middle.
          - Tracklist as two columns ("Side A" / "Side B"), 6-8 entries each, in marker-style type.
          - "From the maker" — one short note, like a dedication on the inside flap.
          - A single faded photo placeholder (use `bg-zinc-300 aspect-[4/3] grayscale opacity-70`) with a caption underneath in italics.
          - Closing CTA labeled "Take the tape" — modest, not loud.

          The whole layout should feel like a personal gift, not a transaction.
        PROMPT
      },
      {
        id: "character-select",
        name: "Character select screen",
        description: "Fighting-game roster grid with creator-as-character stats",
        icon: "video",
        prompt: <<~PROMPT.strip,
          Build this like a fighting-game character select screen. The creator is the playable roster.

          Visual style:
          - Pure black background with neon arcade accents (electric blue, hot pink, lime green).
          - Pixel-style heading font (`font-mono`, `tracking-widest`, `uppercase`).
          - A grid of "character portrait" cards across the top, each with a thick neon border and a glow effect (use `shadow-[0_0_24px_currentColor]`).
          - Stats displayed as bar charts — labeled "Speed", "Power", "Style", "Vibes" with horizontal bars (`bg-pink-500`/`bg-cyan-400`).
          - VS-screen style numerals and slashes between sections.

          Sections:
          - Top: a grid of 6 character portrait cards. The "selected" character (the creator) is the largest one, highlighted with a flashing border (use `animate-pulse`).
          - "Player 1: [Creator Name]" header in arcade type.
          - Character bio block: name, "fighting style" (the creator's actual craft reframed), signature move (their flagship product).
          - Stats panel with the bar charts described above.
          - "Movelist" section listing 3-5 products as combo notations ("↓ ↘ → + Buy = Acquire the ebook").
          - CTA labeled "PRESS START" or "INSERT COIN" — full-width neon banner at the bottom.

          The page should feel like CRT-scan-lines and quarters-on-the-arcade-cabinet energy.
        PROMPT
      },
      {
        id: "museum-exhibit",
        name: "Museum exhibit of my work",
        description: "Curated gallery framing with wall-label microcopy and exhibit signage",
        icon: "bundle",
        prompt: <<~PROMPT.strip,
          Frame this as a museum exhibit of the creator's work. The visitor is walking through a curated show, not a shop.

          Visual style:
          - Off-white walls (`bg-neutral-50`), warm-gray body copy, deep-black headings, all serif type (`font-serif`).
          - Wall-label microcopy in `text-xs uppercase tracking-widest text-zinc-500`.
          - Plenty of whitespace. Section padding `py-24`.
          - One thin black hairline rule between sections.

          Sections:
          - Exhibit title plate: large serif title centered, dates of the "exhibition" below in small caps, then a single descriptive subtitle in italic ("Selected works, [year range]").
          - Curator's note: one column of prose, set narrow (`max-w-prose`), in body serif. Signed at the bottom with the creator's name.
          - Gallery wall: 3-4 large image placeholders arranged asymmetrically, each with a wall-label caption underneath (title, year, medium, materials).
          - "Featured acquisition" block — a single product reframed as the centerpiece of the show, with curator's notes, edition info, and price (in tiny museum-label type).
          - "Visit information" — hours, location-style closing block with a single CTA labeled "Acquire" in lowercase.

          The vibe is quiet, deliberate, and a little reverential. Don't sell. Let the work speak.
        PROMPT
      },
      {
        id: "magazine-spread",
        name: "Magazine spread, not a grid",
        description: "Editorial layout with cover lines, pull quotes, full-bleed photography",
        icon: "newsletter",
        prompt: <<~PROMPT.strip,
          Lay this out like a magazine feature spread — editorial photography, cover lines, pull quotes — not a tile grid of products.

          Visual style:
          - Off-white background (`bg-stone-50`), serif body copy (`font-serif`), bold sans-serif display type for headlines (`font-sans font-black`).
          - Mix of full-bleed image blocks and tight columns of text. Use `columns-2` for body sections.
          - Large drop caps at the start of body paragraphs (`first-letter:text-7xl first-letter:font-bold first-letter:float-left first-letter:mr-2 first-letter:leading-none`).
          - Cover-line callouts in the margins, set in small caps with tracking.

          Sections:
          - Cover-style hero: a single oversized headline running across the page, a deck (subhead) in italic serif, a byline in small caps ("By [Creator Name]"), and a "Cover Story" eyebrow label.
          - Full-bleed photo placeholder (use a `aspect-[16/9] bg-zinc-300`) with a small italic caption underneath.
          - Feature article: two-column body copy with a drop cap. Insert one pull-quote mid-column in oversized italic serif.
          - "Sidebar" boxed block with bullet points or stats, set in sans-serif on a tinted background (`bg-amber-50`).
          - Second photo + caption.
          - Closing CTA reframed as a "Get the issue" line at the end, plus a small "On newsstands now" microcopy.

          The page should reward slow reading, not scanning.
        PROMPT
      },

      # === Reframe the vibe ===
      {
        id: "letter-from-friend",
        name: "Letter from a friend",
        description: "Hand-typed personal letter, no marketing voice, warm and direct",
        icon: "coffee",
        prompt: <<~PROMPT.strip,
          Write this like a letter the visitor is opening — typed on a personal machine, signed by hand, no marketing voice at all.

          Visual style:
          - Cream paper background (`bg-amber-50`), narrow centered column (`max-w-prose`).
          - Body in a typewriter or transitional serif (`font-serif`, `text-zinc-800`).
          - The opening line is the only large type. No giant heading. No CTA bar at the top.
          - Single column. No images except possibly one small handwriting-style signature at the bottom.

          Sections:
          - Date in the top right corner, plain.
          - Opening: "Dear reader," or "Hey —" in plain body serif.
          - 4-6 paragraphs in the creator's voice, conversational, about why this thing exists. No bullet points. No "what's included" sections.
          - Toward the end: "If any of that resonates, I made this for you." Then a one-line link rather than a button (`<a class="underline">Take it home</a>`).
          - Signed at the bottom: "— [Creator Name]" in handwritten-style italic serif.
          - PS at the very end with one extra thought.

          Strip out anything that feels like landing-page copy. If a sentence wouldn't survive in an actual letter, cut it.
        PROMPT
      },
      {
        id: "group-chat",
        name: "Group chat, not LinkedIn",
        description: "Casual, lowercase, unprofessional in the right way",
        icon: "call",
        prompt: <<~PROMPT.strip,
          Write this like a message in the creator's group chat. Casual, lowercase, slightly typo-tolerant, full of side comments. The opposite of a LinkedIn headline.

          Visual style:
          - Plain white background. Body in a friendly sans-serif (Inter, `font-medium`).
          - Lowercase throughout — including the headline and CTAs. No capitalised titles.
          - Sentences run on. Em-dashes everywhere. Occasional `<br>` for dramatic effect.
          - One inline emoji per section, used sparingly. No emoji bullets.
          - Small inline image blocks like screenshotted DMs.

          Sections:
          - Top: "ok so I made a thing" — that's the headline. Below it, 2-3 lines of context in normal body type.
          - "wait what is it" — a short, conversational explanation.
          - "who is this for" — bullets-but-as-sentences ("you, if you've ever...", "your friend who keeps...").
          - Inline "DM-style" testimonial block — render it like a chat bubble (rounded corner, soft background, with the sender's first name above).
          - "ok how much" — price written in body copy, not a card. ("it's $29, link below").
          - Closing line: "anyway, here it is →" with the CTA inline.

          The page should read like a text from a friend, not a sales pitch. Refuse to be slick.
        PROMPT
      },
      {
        id: "dive-bar",
        name: "Dive bar version of my homepage",
        description: "Dim lighting, well-loved wear, written-on-coasters energy",
        icon: "coffee",
        prompt: <<~PROMPT.strip,
          Build the dive-bar version of the creator's homepage. Dim, well-loved, slightly worn — the opposite of a polished startup landing page.

          Visual style:
          - Deep wood-brown or warm-charcoal background (`bg-stone-800`), dim amber accent (`text-amber-300`).
          - Body in a humanist serif (`font-serif`), slightly small, slightly tight (`text-sm leading-relaxed`).
          - Single bare-bulb lighting effect — center the hero on the page like it's lit from above with everything else in shadow.
          - Chalkboard-feel section labels (`font-mono uppercase tracking-widest text-amber-200`).
          - One handwritten-style "tonight only" specials board.

          Sections:
          - Hero: low-key headline (no exclamation marks, no "Unlock!"), one sentence subtitle, a single understated CTA labeled "pull up a stool".
          - "Tonight's specials" — a chalkboard-style block listing 3-4 products in handwritten type with prices.
          - "Regulars" — testimonials written as bartender's-notebook entries ("— D., Tuesday, 11pm").
          - "House rules" — a small list of opinions about the work, in small caps.
          - Closing: "Last call" CTA in amber on charcoal.
          - Footer: "open late" microcopy.

          The page should feel like a place you'd want to spend an hour, not a funnel.
        PROMPT
      },
      {
        id: "menu",
        name: "Restaurant menu",
        description: "Prix-fixe layout, course-by-course, ingredient lists, sommelier energy",
        icon: "physical",
        prompt: <<~PROMPT.strip,
          If the creator's work were a restaurant, this is the menu. Lay it out like a prix-fixe card at a thoughtful neighborhood spot.

          Visual style:
          - Cream paper background (`bg-stone-50`), forest-green or deep-burgundy accent.
          - All-serif typography (`font-serif`). Centered alignment.
          - Section labels in small caps ("APPETIZERS", "MAINS", "DESSERT", "DIGESTIF") in tracking-widest.
          - Dotted leaders between item name and price (use `border-b border-dotted` rows or a `flex justify-between` with a dotted divider).
          - Italics for ingredient lists and provenance notes.

          Sections:
          - Header: restaurant-name-style title in large serif, "Est. [year]" subtitle in italic.
          - "Tonight's tasting" — a 5-course menu where each "course" is one of the creator's products reframed: name as the dish, italic ingredient list as the description, price on the right.
          - Wine pairing block — one or two products framed as "pairings" with the main offering.
          - "From the chef" — a short paragraph from the creator in italic body type.
          - "Reservations" CTA — small, refined, all-caps, set in the accent color.
          - Footer: "Cash only" / "Walk-ins welcome" microcopy joke.

          The whole page should feel like dining at a place that knows what it's doing.
        PROMPT
      },
      {
        id: "fan-site",
        name: "Fan site for myself",
        description: "Self-aggrandizing in a winking way, devotional layout, top-ten lists",
        icon: "course",
        prompt: <<~PROMPT.strip,
          Build a fan site — for the creator — by the creator. Self-aggrandizing in a winking, fully-aware way. The joke is that this exists.

          Visual style:
          - Bright pastel background (`bg-pink-100`, `bg-yellow-100`), heavy use of pink and gold accents.
          - Mid-2000s fan-site type: chunky sans-serif headings, bubbly drop shadows, slight gradients.
          - Star icons (`★`) scattered throughout. Sparkle emojis at the start of section headings.
          - "Webring" style row of placeholder fan-site links at the bottom.
          - Slightly glossy "stickers" rotated at small angles (`-rotate-3`).

          Sections:
          - Hero banner: "[Creator Name] — The Unofficial Fan Site" in big bubbly type, with a "since [year]" badge in the corner.
          - "About them" — third-person bio that's a little too enthusiastic.
          - "Top 10 [Creator Name] Moments" — a numbered list, dramatic.
          - "Discography" / "Filmography" / "Bibliography" — the creator's products listed as canonical works with release dates and "★★★★★" reviews.
          - "Visitor sign-the-guestbook" placeholder block.
          - CTA labeled "Become a fan — official merch here" with a single product.
          - Footer: "Not affiliated with [Creator Name]. (Yes I am.)"

          Lean fully into the bit. The reader is in on the joke.
        PROMPT
      },
      {
        id: "anti-squarespace",
        name: "Opposite of a Squarespace template",
        description: "Reject every default — wrong fonts, weird proportions, refusal to be generic",
        icon: "digital",
        prompt: <<~PROMPT.strip,
          Refuse every Squarespace default. Wrong fonts. Weird proportions. Section padding that "shouldn't" work. The page must look like nobody else's.

          Visual style:
          - Unexpected color pairing — try `bg-lime-200` with `text-purple-900`, or `bg-orange-300` with `text-emerald-900`.
          - One serif paired with one mono — never just two sans-serifs.
          - Asymmetric layout: 70/30 column splits, content pulled hard to one side, intentional empty space on the other.
          - One element does something a template wouldn't: a giant section heading rotated 90° in the margin, body text in a single tall narrow column, oversized bullet glyphs.
          - Generous, intentional ugliness in one specific place (a hand-drawn-feeling border, a chunky underline, a slab of solid color).

          Sections:
          - A hero that doesn't fill the viewport. Title on the left third, no image, the right two-thirds left empty on purpose.
          - "What this is" — one paragraph, set narrow, in mono.
          - A wide horizontal band of solid accent color with a single bold statement in it.
          - "What's inside" — a list, but the bullets are oversized custom glyphs (`→`, `■`, `▲`).
          - Pricing block: just text, large and confident. No card. No shadow.
          - Footer that's a single line of mono.

          The reader should be unable to identify what template this came from, because it doesn't come from one.
        PROMPT
      },

      # === Era / aesthetic anchors ===
      {
        id: "tasteful-geocities",
        name: "Tasteful GeoCities, 1998",
        description: "Web 1.0 with intention — tiled backgrounds, sectioned tables, dignified",
        icon: "ebook",
        prompt: <<~PROMPT.strip,
          Channel GeoCities 1998 — but tastefully. A personal website made by someone who knew exactly what they were doing in HTML 4.

          Visual style:
          - Tiled background pattern (use `bg-[url('data:image/svg+xml...')]` or a `bg-repeat` div with a subtle pattern).
          - Times New Roman / Georgia headings (`font-serif`), Verdana / Geneva body (`font-sans`).
          - Hard-edged, table-style section borders (use `border-2 border-zinc-800`).
          - One visible "Best viewed in 800×600" microcopy at the bottom.
          - Two-tone color scheme: a single deep accent (forest green, burgundy, navy) with cream.
          - Animated GIF placeholders — small rotating glyphs near the headline.

          Sections:
          - Top banner: a centered title with horizontal rule underneath (`<hr>`-style), set in classic serif.
          - "Welcome!" intro paragraph in body type, with `<font color="#...">` -style colored words (just use spans with colors).
          - "Navigation" — a vertical sidebar of links rendered as bordered table cells.
          - "What's New" — a dated list with timestamps ("Updated: March 12, 1998").
          - "About me" — a paragraph or two, no photo required.
          - "Sign my guestbook" CTA.
          - "Webring" row of fake adjacent-site links.
          - Footer: visitor counter graphic placeholder, "© [Year] [Name]. Best viewed in Netscape Navigator."

          The page should feel curated, not chaotic. This is the version of GeoCities that aged well.
        PROMPT
      },
      {
        id: "tumblr-2014",
        name: "Tumblr 2014 personal blog",
        description: "Pastel goth, infinite-scroll reblog culture, soft serif headlines",
        icon: "newsletter",
        prompt: <<~PROMPT.strip,
          Channel a 2014 Tumblr personal blog — pastel goth, soft-serif headlines, infinite-scroll reblog culture energy.

          Visual style:
          - Lavender or dusty-pink background (`bg-purple-100`, `bg-rose-100`).
          - Headlines in a soft serif (`font-serif`, italics encouraged). Body in `font-sans`.
          - Generous line-height. Reading column narrow (`max-w-2xl mx-auto`).
          - Soft drop shadows under image blocks. Rounded corners (`rounded-2xl`).
          - Heart icons and small caps section labels.

          Sections:
          - Header: a single italic-serif blog title and a one-line tagline. No nav bar.
          - "Posts" — a vertical stack of 3-4 mock blog entries: photo placeholder + short body + tags at the bottom (`#aesthetic #softgrunge #writing`).
          - One entry is a quote card (`bg-purple-200` with the quote in italic serif, attribution beneath).
          - Reblog-style note count at the bottom of each post ("12,453 notes").
          - "About me" sidebar — short bio, list of interests, and a small avatar circle.
          - CTA reframed as a "click here to read more" link at the very bottom — modest, blog-style.

          The vibe is melancholic, soft, and absolutely Of Its Time.
        PROMPT
      },
      {
        id: "y2k-shopping-channel",
        name: "Y2K shopping channel",
        description: "QVC chyron banners, 'limited time only', metallic gradients, urgent voice",
        icon: "commission",
        prompt: <<~PROMPT.strip,
          Build this like a Y2K shopping channel broadcast. QVC chyron banners, metallic gradients, "limited time only", and an urgent VO voice in the copy.

          Visual style:
          - Metallic silver-to-blue gradient background (`bg-gradient-to-b from-slate-300 to-blue-400`).
          - Chunky bevelled buttons with hard inner-shadow (`shadow-inner`).
          - "TV chyron" bar across the bottom (a sticky `bg-red-600 text-white` band) saying "ON AIR — LIMITED OFFER".
          - Pixel-perfect-feeling sans-serif type, italics for urgency.
          - Bright price callouts in red and yellow ("WAS $89.99 — NOW $39.99!!").
          - A static-noise effect overlay near the top (low-opacity zinc texture).

          Sections:
          - Top: "ON AIR" chyron and a "VIEWERS CALLING NOW: 2,347" ticker.
          - Hero: an oversized "AS SEEN ON TV"-style headline, the product name in big chunky type, an exclamation-heavy tagline.
          - "Operators standing by" CTA in a glossy beveled button.
          - "WHAT YOU GET" — a numbered list with red checkmarks and "$X value!" callouts after each item.
          - "But wait, there's more!" bonus section listing an extra freebie.
          - "Call now" price block with strikethrough on original price.
          - "Order in the next 10 minutes" countdown stub at the bottom.
          - Footer chyron: "Offer expires soon — call 1-800-[creator]."

          Be loud. Be gauche. Be 1999 at 3am.
        PROMPT
      },
      {
        id: "vinyl-liner-notes",
        name: "Liner notes from a vinyl record",
        description: "Gatefold layout, dense credits, recorded-at-such-and-such studio energy",
        icon: "audio",
        prompt: <<~PROMPT.strip,
          Lay this out like the liner notes from a vinyl gatefold sleeve. Dense credits, intimate sleeve notes, recorded-at-such-and-such-studio energy.

          Visual style:
          - Cream paper background with a faint texture (`bg-stone-100`).
          - All-serif typography (`font-serif`). Body small and dense (`text-sm leading-relaxed`).
          - Two-column layout for the sleeve notes block.
          - Tracklist in small monospaced type with running-time markers.
          - Tasteful black-and-white photo placeholder in the center of the spread.
          - A subtle drop-cap on the first paragraph of the sleeve notes.

          Sections:
          - Top: artist name + record title in elegant serif. Year and label below in small caps.
          - "Side A / Side B" tracklist in monospaced type, two columns.
          - Sleeve notes essay: 3-4 paragraphs of intimate prose explaining the context of the work, set in two columns with a drop cap.
          - "Credits" block: dense list of "Recorded at:", "Produced by:", "Special thanks to:", set in small type with `font-bold` labels.
          - A pull-quote from a fictional review of the work, set in italics.
          - "Available on" CTA framed as a record-label-style line ("Out now on [Creator Records]") with a small button.
          - Footer: catalog number microcopy ("Cat. #001 — Edition of 500").

          The whole page should feel like something you'd read on the train home with the record in your bag.
        PROMPT
      },

      # === Identity prompts ===
      {
        id: "brain-as-webpage",
        name: "My brain as a webpage",
        description: "Stream-of-consciousness layout, sidebars of unrelated obsessions, no hierarchy",
        icon: "subscription",
        prompt: <<~PROMPT.strip,
          Render the creator's brain as a webpage. Stream-of-consciousness layout. Sidebars of unrelated obsessions. No clear hierarchy. Tangents welcome.

          Visual style:
          - Off-white background, plain serif body (`font-serif`).
          - Many short blocks of text in different sizes, stitched together — no obvious section structure.
          - Marginalia: small annotations in italic serif pushed to the side margin (`absolute -left-32 italic text-xs text-zinc-500` on each block).
          - Footnotes at the bottom of blocks (`text-xs` with superscript numbers).
          - Inline hyperlink underlines everywhere (`underline decoration-zinc-400`).
          - One central column, but with content "leaking" out into the margins via marginalia and pull-quote callouts.

          Sections (loose):
          - A short opening manifesto — "things I think about, in no particular order".
          - A block on "what I'm currently obsessed with" (3-4 items, one paragraph each, unrelated to one another).
          - A list of "tabs I have open right now" — links to articles, songs, ideas.
          - A pull quote, large and italic, from a writer the creator admires.
          - "Things I made" — the products surfaced as items in a recommended-reading list, not as products.
          - A footnote-style endnote section at the bottom citing whatever was referenced.
          - The CTA is reframed: "if any of this resonates, you might like this →" with a link.

          The page should feel like reading someone's notebook. There should be no marketing voice anywhere.
        PROMPT
      },
      {
        id: "30-second-intro",
        name: "30-second intro to a stranger",
        description: "Elevator-pitch single-screen layout — no scroll required, every word earned",
        icon: "digital",
        prompt: <<~PROMPT.strip,
          Design this as the 30-second introduction the creator would give a stranger at a party. One screen. No scroll. Every word has to earn its place.

          Visual style:
          - Pure white background, deep-black type. No accent color except for one link.
          - Single column, centered, `max-w-xl mx-auto`.
          - Vertical centering — the content sits in the middle of the viewport, not the top.
          - Large display serif for the first line. Sans-serif for the rest.
          - No images. No icons. No header. No footer. No nav.

          Sections (all in one viewport):
          - Line 1 (largest): the creator's name, in serif.
          - Line 2: what they do, in one sentence ("I [verb] [thing] for [audience].").
          - Line 3: one more sentence of differentiation ("Specifically, [the angle].").
          - A 3-item list, each item a single line: a recent project, a current preoccupation, a thing they're known for.
          - A single underlined link: "More →".

          That's the whole page. No CTA buttons. No social proof. No pricing. The link goes somewhere else if the visitor wants more.

          Treat the constraint seriously: if it doesn't fit in one viewport on a laptop, cut something.
        PROMPT
      },
      {
        id: "dinner-party",
        name: "Dinner party for my customers",
        description: "Hospitable host energy — place settings, name cards, considered atmosphere",
        icon: "bundle",
        prompt: <<~PROMPT.strip,
          Design this like the creator is hosting a small dinner party for their customers. Considered, warm, hospitable, slightly formal in a charming way.

          Visual style:
          - Warm-white background (`bg-stone-50`), candlelight-amber accent (`text-amber-700`).
          - Serif headings, sans-serif body. Tight column widths (`max-w-prose`).
          - Hand-drawn-feeling underlines beneath section titles (`border-b border-amber-700`).
          - Italic serif for "menu cards" and notes.
          - Generous whitespace and `py-16` between sections — the page breathes like a slow evening.

          Sections:
          - "An invitation" header: serif, in italic, with the date stylized like an event invite ("This evening — [season, year]").
          - "From your host" — a paragraph from the creator welcoming the visitor by name (generic "friend" or "you").
          - "Tonight's offerings" — products presented as courses on a menu card, each with a name and a one-sentence description.
          - "Place setting" — a small block about who else has joined, framed as testimonials but in the "I'm-glad-you-could-make-it" voice.
          - "Stay a while" — a closing block with a single CTA: "Pull up a chair" or "Reserve your seat", set in serif on the amber accent.
          - Footer: "Thank you for coming. — [Creator Name]" in italic.

          The page should feel like the host actually wants the visitor there, not like a funnel.
        PROMPT
      },
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
