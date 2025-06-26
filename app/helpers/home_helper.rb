# frozen_string_literal: true

module HomeHelper
  def discovery_items_data
    [
      { type: :icon, icon: "discover/animation.svg", path: "3d" },
      { type: :tag, text: "notion template", path: "business-and-money" },
      { type: :icon, icon: "discover/audio.svg", path: "audio" },
      { type: :tag, text: "investing", path: "business-and-money" },
      { type: :icon, icon: "discover/crafts.svg", path: "business-and-money" },
      { type: :tag, text: "instagram", path: "business-and-money" },
      { type: :icon, icon: "discover/comics.svg", path: "comics-and-graphic-novels" },
      { type: :tag, text: "comic", path: "comics-and-graphic-novels" },
      { type: :icon, icon: "discover/design.svg", path: "design" },
      { type: :tag, text: "vj loops", path: "films" },
      { type: :icon, icon: "discover/drawing.svg", path: "drawing-and-painting" },
      { type: :tag, text: "luts", path: "films" },
      { type: :icon, icon: "discover/education.svg", path: "education" },
      { type: :tag, text: "fitness", path: "fitness-and-health" },
      { type: :icon, icon: "discover/writing.svg", path: "writing-and-publishing" },
      { type: :tag, text: "workout program", path: "fitness-and-health" },
      { type: :icon, icon: "discover/film.svg", path: "films" },
      { type: :tag, text: "printable", path: "self-improvement" },
      { type: :icon, icon: "discover/sports.svg", path: "fitness-and-health" },
      { type: :tag, text: "productivity", path: "self-improvement" },
      { type: :icon, icon: "discover/games.svg", path: "gaming" },
      { type: :tag, text: "programming", path: "software-development" },
      { type: :icon, icon: "discover/music.svg", path: "music-and-sound-design" },
      { type: :tag, text: "windows", path: "software-development" },
      { type: :icon, icon: "discover/photography.svg", path: "photography" },
      { type: :tag, text: "theme", path: "software-development" },
    ]
  end

  def testimonials_data
    [
      {
        quote: "I launched MaxPacks as an experimental side gig; but within 2 years those Procreate brushes were earning more than my 6-figure salary in CG. Leaving in favor of Gumroad enabled me to explore other aspects of my art, develop new hobbies, and finally prioritize my personal life.",
        avatar_path: "creators/maxulichney-round.svg",
        name: "Max Ulichney",
        description: "Sells Procreate brush packs"
      },
      {
        quote: "For years, I had a goal to develop 'passive' income streams, but struggled to make that a reality. Last year, I started selling informational products on Gumroad and since then have made $10k+ per month building products that I love.",
        avatar_path: "creators/stephsmith-round.svg",
        name: "Steph Smith",
        description: "Sells content tutorials"
      },
      {
        quote: "Originally, I took pre-orders for my Trend Reports on Gumroad. But I received... exactly $0. So I changed tactics: I made half of my report free, and the other half paid. Today, 99% of Trends.VC revenue is recurring in the form of annual and quarterly subscriptions.",
        avatar_path: "creators/trendsvc-round.svg",
        name: "trendsvc",
        description: "Sells business insights and expertise"
      },
      {
        quote: "I love Gumroad because it can't be any simpler. I upload a file, set a price, and I can start selling on the internet. The money I make from my sales lands directly in my bank account every Friday.",
        avatar_path: "creators/danielvassalo-round.svg",
        name: "Daniel Vassallo",
        description: "Sells business insights and expertise"
      }
    ]
  end
end
