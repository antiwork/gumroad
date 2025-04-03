# frozen_string_literal: true

class AdultKeywordDetector
  # TODO: Add "pin-up" and "AB/DL". We may have to revisit our approach so we can include non-alphabet characters in the
  # list of adult keywords

  ADULT_KEYWORD_REGEX = Regexp.new(
    "\\b(" +
      ["futa", "pussy", "bondage", "bdsm", "lewd", "ahegao", "nude", "milking", "topless", "lolita", "lewds",
       "creampie", "dildo", "gape", "semen", "cuckold", "hairjob", "tickling", "hogtied", "uncensored", "thong",
       "pinup", "impregnation", "gagged", "hentai", "squirt", "orgasm", "virginkiller", "abdl", "crotch",
       "breast inflation", "ahri", "granblue", "lingerie",
       "boudoir", "kink", "shibari", "gutpunch", "gutpunching", "abs punch", "necro",
       "vibrator", "fetish", "nsfw", "saucy", "footjob", "joi"].join("|") +
    ")\\b"
  ).freeze

  # From https://stackoverflow.com/a/4052294/3315873
  # There are three cases in Unicode, not two. Furthermore, you also have non-cased letters.
  # Letters in general are specified by the \pL property, and each of these also belongs to exactly one of five
  # subcategories:
  #
  # uppercase letters, specified with \p{Lu}; eg: AÇǱÞΣSSὩΙST
  # titlecase letters, specified with \p{Lt}; eg: ǈǲSsᾨSt (actually Ss and St are an upper- and then a lowercase letter, but they are what you get if you ask for the titlecase of ß and ﬅ, respectively)
  # lowercase letters, specified with \p{Ll}; eg: aαçǳςσþßᾡﬅ
  # modifier letters, specified with \p{Lm}; eg: ʰʲᴴᴭʺˈˠᵠꜞ
  # other letters, specified with \p{Lo}; eg: ƻאᎯᚦ京

  # We use this regex to get "words" from text.
  # Matches
  #   a sequence of one or more letters starting with an uppercase or titlecase letter
  #   OR
  #   a sequence of one more letters made up of only uppercase and/or titlecase letters
  TOKENIZATION_REGEX = /((?:[\p{Lu}\p{Lt}]?[\p{Ll}\p{Lm}\p{Lo}]+)|(?:[\p{Lu}\p{Lt}])+)/

  # We use this regex to change non-letter characters to a space.
  # Matches any unicode letter or a space.
  NOT_LETTER_OR_SPACE_REGEX = /[^\p{Lu}\p{Lt}\p{Ll}\p{Lm}\p{Lo} ]/

  def self.adult?(text)
    tokens = if text.present?
      # 1. Change all non-letters characters to a blank space
      # 2. Split the text into words
      # 3. Make all the words lower-case
      text.gsub(NOT_LETTER_OR_SPACE_REGEX, " ").scan(TOKENIZATION_REGEX).flatten.map(&:downcase)
    else
      []
    end

    tokens_as_string = tokens.join(" ")

    ADULT_KEYWORD_REGEX.match?(tokens_as_string)
  end
end
