# frozen_string_literal: true

# Ai::StoreAgentService powers the conversational "Agent" dashboard tab. The seller chats with an
# assistant that can answer questions about their store and *propose* changes to it.
#
# The agent runs on Anthropic's Claude Opus 4.7 (via Ai::AnthropicClient). Opus 4.7 currently leads
# the vending-bench leaderboard for autonomous commercial operation, so it is the strongest model
# for the agent's actual job: helping a creator run and grow their store.
#
# Safety model:
#   - READ tools (api_read) run automatically and only ever query data the seller already owns. They
#     are scoped to current_seller, so the agent can never read another seller's data.
#   - WRITE tools (api_write) DO NOT mutate anything here. They return a structured "proposed action"
#     that the frontend renders as a confirmation card. Nothing is applied until the seller explicitly
#     confirms, at which point the controller hands the action to Ai::StoreAgentActionExecutor. This
#     keeps an LLM hallucination or a prompt injection from silently changing a store.
#
# The loop is a standard Anthropic tool-use exchange: we send the system prompt + conversation + tool
# schemas, run any read tools the model asks for, feed the results back as tool_result blocks, and
# repeat until the model returns a normal assistant message (optionally carrying one proposed write).
class Ai::StoreAgentService
  include CurrencyHelper

  class Error < StandardError; end

  MODEL = Ai::AnthropicClient::DEFAULT_MODEL
  # Passed to Ai::AnthropicClient as its READ timeout. For the streamed reply this bounds silence
  # between chunks (not the total generation time — a long healthy stream is fine); for the buffered
  # calls it bounds the wait for the full response. Production showed a steady stream of 60-second
  # network timeouts on real (slow but working) generations, so this is deliberately generous — the
  # client fails fast on connect problems and retries transient failures on its own.
  REQUEST_TIMEOUT_IN_SECONDS = 120
  # Base upper bound on model turns per reply (each turn may run one or more tools). This has to
  # leave room for pagination: list endpoints return 10 items per page and the system prompt tells
  # the model to walk EVERY page for "all of X" tasks, so each page fetch consumes one turn and the
  # final answer needs one more. The previous cap of 5 meant a seller with more than ~40 products
  # hit the generic "couldn't finish" fallback on exactly the catalog-wide tasks the pagination
  # rule exists for. 25 turns covers catalogs of roughly 240 items while still bounding the cost
  # of a runaway tool loop. A late phantom-staging claim can reserve the two tightly scoped turns
  # below when the normal budget no longer has room for them.
  MAX_TOOL_ITERATIONS = 25
  MAX_MESSAGE_LENGTH = 2_000
  # Anthropic requires max_tokens on every request. This cap has to fit more than a brief chat
  # reply: when the agent edits a product, the model must emit the ENTIRE new value (for example a
  # long description's full HTML) inside the tool call's JSON arguments. A cap sized only for text
  # replies (this was previously 1,500) cut those tool calls off mid-JSON, which surfaced to the
  # seller as a generic "Something went wrong" error. 8,192 comfortably fits real product
  # descriptions while still bounding the cost of a runaway turn.
  MAX_REPLY_TOKENS = 8_192
  # What the seller sees when a model turn still hits MAX_REPLY_TOKENS (stop_reason "max_tokens").
  # A truncated turn is unusable — a cut-off tool call has unparseable arguments, and a cut-off
  # text reply would silently present half an answer as if it were complete — so we replace it
  # with an honest ask to scope the request down instead of streaming garbage or raising.
  TRUNCATED_REPLY = "That's too much for me to handle in one go — try asking me to change or " \
                    "summarize a smaller section, and I'll take it from there."
  # Phrases a reply uses when it asserts THIS turn staged a change for the creator to confirm. Such
  # a reply is only TRUE when this same turn produced a proposed action: the confirmation card the
  # creator is told to click is rendered from that action, so with no action there is no card and
  # the creator is hunting a button that cannot exist. The model does occasionally write the claim
  # without calling api_write (roughly one staging claim in seven, measured in production), which
  # reads to the creator as the agent lying to them.
  #
  # Precision matters more than recall here, because a match REPLACES the model's reply: a truthful
  # reply wrongly matched would tell the creator a change doesn't exist when it does. Each pattern
  # therefore starts at a sentence/current-assertion boundary. Conditional and negated clauses such
  # as "if it is staged" and "it isn't staged" cannot match merely because they contain the same
  # words, while a later assertion in "nothing was staged before, but I've staged it now" still can.
  STAGED_CLAIM_BOUNDARY = /
    (?:\A|[.!?;:—–]\s*|\s-\s*|\n+\s*|\b(?:but|however|though)\s+|
       \b(?:although|yet|so)\s+(?=i\b)|,\s*and\s+(?=i\b))
  /ix
  STAGED_CLAIM_NEGATED_OBJECT = /
    \s+(?:nothing|none|no\s+(?:product\s+)?(?:change|changes?|update|updates?|discount|discounts?|
      action|actions?|offer|offers?|code|codes?|edit|edits?))\b
  /ix
  # Things the agent stages. The subjectless opener ("Staged deletion of the draft.") needs one of
  # these to follow, so prose about the staging feature in general cannot be mistaken for a claim
  # that this turn staged something. The re-staging anchor below reuses the same list: it used to
  # carry its own copy, the two drifted, and re-staging claims with an object the copy had missed
  # reached creators as phantom confirmation prompts.
  STAGED_CLAIM_ACTION_NOUN = /
    (?:deletions?|removals?|creations?|additions?|renames?|renaming|archival|
       updates?|changes?|edits?|fixe?s?|
       discounts?|discount\s+codes?|offer\s+codes?|offers?|codes?|
       price\s+changes?|products?(?:\s+updates?)?|
       publish(?:ing)?|unpublish(?:ing)?)
  /ix
  STAGED_CLAIM_HISTORICAL_TAIL = /
    (?:
      \s+(?:(?:it|that|this)|(?:the|that|this|your)\s+
        (?:change|update|discount|offer|code|edit))?\s*
      (?:yesterday|previously|earlier|before|many\s+times|
        last\s+(?:night|week|month|year)|in\s+the\s+past)\b
      |
      \s+(?:(?:it|that|this)\s+)?(?:from|on|in)\s+(?:my|the)\s+
        (?:earlier|previous)\s+message\b
      |
      # A reply pointing back at a card the creator can still click is truthful, and the model
      # phrases the point-back many ways ("...the price change in my previous message", "...is on
      # my previous message"). It has to be MY earlier message: "the discount you asked for in
      # your previous message" describes the creator's request, and the staging claim wrapped
      # around it is about this turn.
      #
      # A sentence that also says the old card is gone is not a point-back either — re-staging
      # because the creator can't see the card is the single most common way this bug is reported,
      # so those must still reach the guard. "again" has to sit on the staging verb itself
      # ("I staged it again"), because "tap that card again" is an instruction about a card that
      # IS there, and treating it as re-staging would swallow the truthful point-back.
      # The re-staging verb takes a named object as readily as a pronoun ("I've staged the discount
      # again"), so the anchor allows both. The object list is STAGED_CLAIM_ACTION_NOUN rather than
      # a copy of it, so widening what the agent can stage widens this anchor with it.
      (?!\s+(?:(?:it|that|this|them|those|both)\s+|
        (?:a|an|the|that|this|these|those|your|my|two|both)\s+#{STAGED_CLAIM_ACTION_NOUN}\s+)?again\b)
      # The dead-card markers scan to the end of the sentence, not just the clause holding the
      # staging verb: "I've staged the update in my previous message; that card is gone now" is a
      # re-staging claim, and stopping the scan at `;` or a dash loses it. The cost is that a
      # marker word used innocently in a later clause ("...tap that card again; your product photo
      # is missing") also cancels the escape. That trade is deliberate: the narrow scan was tried
      # and reverted because it let four real dead-card shapes slip past the guard.
      (?![^.!?\n]*\b(?:new\s+card|another\s+card|gone|expired|disappeared|vanished|missing|empty|
        didn['’]t\s+render|no\s+longer|isn['’]t\s+there|not\s+there|can['’]t\s+see|
        couldn['’]t\s+(?:see|find))\b)
      [^.!?\n]*\b(?:my|the)\s+(?:earlier|previous)\s+message\b
      |
      [^.!?\n]*\b(?:before|many\s+times|in\s+the\s+past)\b
    )
  /ix
  # "not already applied" still means a proposal is pending. Only a positive assertion that the
  # action completed excuses staging language.
  STAGED_CLAIM_COMPLETED_TAIL = /
    [^.!?\n]*
    (?:
      \b(?:you|i)(?:['’]ve|\s+have)?\s+already\s+
        (?:confirmed|approved|applied)\b
      |
      \b(?:it|that|this|the\s+(?:change|update|discount|offer|code|edit))
      (?:
        (?:['’]s|\s+(?:is|was))\s+already\s+
          (?:confirmed|approved|applied|live|done)\b
        |
        \s+has\s+already\s+been\s+(?:confirmed|approved|applied)\b
      )
      |
      (?:,\s*|\b(?:and|but)\s+)(?<!not\s)(?<!n['’]t\s)already\s+
        (?:confirmed|approved|applied|live|done)\b
    )
  /ix
  # Telling the creator to act on the card. The model does not stick to the word "confirm": in
  # production it also writes "Approve it", "tap it whenever you're ready" and "click the card".
  # Each verb needs an object that refers to the card or the change, so ordinary product advice
  # such as "click Publish when you're happy with it" cannot match.
  STAGED_CLAIM_CARD_INSTRUCTION = /
    \b(?:please\s+)?(?:confirm|approve|tap|click|hit|press)\s+
      (?:(?:on|it)\s+)?
      (?:it|that|this|
         (?:the|that|this|your)\s+(?:confirm(?:ation)?\s+)?(?:card|button))
    \b
  /ix
  STAGED_CLAIM_CURRENT_CUE = /
    (?:
      \b(?:again|now)\b
      |
      \bfor\s+(?:your\s+)?(?:confirmation|approval)\b
      |
      \bready\s+
        (?:(?:for\s+you\s+)?to\s+(?:confirm|approve)|
           for\s+(?:your\s+)?(?:confirmation|approval))\b
      |
      (?:[:,;—–-]\s*|[.!]\s*|\band\s+)(?:please\s+)?(?:confirm|approve)\b
      |
      (?:[:,;—–-]\s*|[.!]\s*|\b(?:and|then)\s+)#{STAGED_CLAIM_CARD_INSTRUCTION}
    )
  /ix
  STAGED_CLAIM_CONDITIONAL_TAIL = /
    (?:
      \A\s*(?:if|when|whenever|once)\b
      |
      \b(?:would|could)\s+(?:be\s+)?(?:staged|prepared|ready|appear)\b
      |
      \b(?:staged|prepared)\s+(?:if|when|whenever)\b
    )
  /ix
  # A finite verb after the noun means the noun was the sentence SUBJECT, not what the agent
  # staged: "Staged deletion of the draft is permanent" describes the feature. The list only has
  # to cover verbs that can follow a noun phrase, so it stays short — and a verb missing from it
  # only costs a false positive, which is the failure this whole guard exists to avoid.
  STAGED_CLAIM_PREDICATE_VERB = /
    (?:is|are|was|were|isn['’]t|aren['’]t|be|being|been|becomes?|remains?|stays?|
       removes?|deletes?|erases?|wipes?|means?|happens?|takes?|needs?|requires?|
       appears?|applies|apply|waits?|wants?|shows?|goes|does|do|doesn['’]t|
       has|have|had|can|can['’]t|cannot|will|won['’]t|would|could|should|might|must)\b
  /ix
  # The rest of a noun phrase between the noun and its verb ("of the very last remaining draft
  # is..."). Length is not capped: a subject can be arbitrarily long, and a cap just moves the
  # false positive one adjective further out. What bounds it instead is the clause — it stops at
  # any punctuation, because words after a sentence break belong to the instruction rather than
  # the subject.
  #
  # Two token shapes look like a clause break but stay inside the subject, and each is admitted
  # only on the evidence of what follows it: a conjunction leading another noun phrase ("and the
  # archived copy"), and a relative pronoun with its own subject ("that I reviewed"). A pronoun
  # after the conjunction, or a verb straight after the relative pronoun, really does start a new
  # clause, which is what keeps "Staged the change and it is ready to confirm" and "Staged the
  # update that will apply to all products" matching as claims.
  #
  # An aside is punctuation that opens and CLOSES inside the clause, so it modifies the subject
  # rather than ending it ("of the draft (the one from March) is permanent"). Requiring the closing
  # mark is what separates it from a sentence break: one unpaired comma or dash still ends the
  # subject, and the words after it belong to the instruction.
  STAGED_CLAIM_SUBJECT_ASIDE = /
    (?:
      \s*\([^()\n]*\)
      |
      \s*"[^"\n]*"
      |
      \s*[“][^”\n]*[”]
      |
      \s*,[^,.!?\n]*,
      |
      \s*[—–][^—–.!?\n]*[—–]
    )
  /x
  STAGED_CLAIM_SUBJECT_FILLER = /
    (?:
      #{STAGED_CLAIM_SUBJECT_ASIDE}
      |
      \s+(?:and|but)(?=\s+(?:the|a|an|your|its|their|my|two|both)\b)
      |
      \s+(?:that|which|who)(?=\s+(?!#{STAGED_CLAIM_PREDICATE_VERB})[a-z])
      |
      \s+(?!(?:and|but|so|then|it|that|this|which|who)\b)\#?[a-z0-9][-'’a-z0-9]*
    )*
  /ix
  # Noun-phrase-then-verb, i.e. the noun was the subject. The verb is only disqualifying when its
  # predicate is a general property of the feature; "Staged deletion of the draft is ready for your
  # confirmation" puts the same verb in front of a claim about this turn, so those predicates are
  # excluded from the exclusion. A verb that ends the clause is likewise not one: the words after it
  # are what make it a general property, and without them ("the change that you want.") the verb
  # belongs to a relative clause the filler just walked through.
  STAGED_CLAIM_SUBJECT_PREDICATE = /
    #{STAGED_CLAIM_SUBJECT_FILLER}\s+#{STAGED_CLAIM_PREDICATE_VERB}
    (?!\s+(?:just\s+|now\s+|been\s+)*(?:ready|staged|prepared|queued|waiting|set\s+up)\b)
    (?=\s+[a-z])
  /ix

  STAGED_CLAIM_PATTERNS = [
    # First-person staging is current when it uses the present-perfect/current modifiers, or when
    # the same sentence tells the seller to confirm. Plain historical "I staged..." needs neither.
    /
      #{STAGED_CLAIM_BOUNDARY}
      (?:now\s+)?
      i
      (?:
        (?:['’]ve|\s+have)\s+
          (?:(?:just|now|been)\s+|(?:went|gone)\s+ahead\s+and\s+)*staged\b
        |
        \s+(?:(?:just|now)\s+|went\s+ahead\s+and\s+)+staged\b
        |
        \s+staged\b(?=[^.!?\n]*#{STAGED_CLAIM_CURRENT_CUE})
      )
      (?!#{STAGED_CLAIM_NEGATED_OBJECT})
      (?!#{STAGED_CLAIM_HISTORICAL_TAIL})
      (?!#{STAGED_CLAIM_COMPLETED_TAIL})
      (?![^.!?\n]*\?)
    /ix,
    # Contextual pronouns are specific enough to assert the current proposal. Local exclusions keep
    # prior-message, completed, conditional, and question forms from being rewritten.
    /
      #{STAGED_CLAIM_BOUNDARY}
      (?:now\s+)?
      (?:it|that|this)(?:['’]s|\s+(?:is|has\s+been))
      \s+(?:just\s+|now\s+|been\s+)*staged\b
      (?!#{STAGED_CLAIM_NEGATED_OBJECT})
      (?!#{STAGED_CLAIM_HISTORICAL_TAIL})
      (?!#{STAGED_CLAIM_COMPLETED_TAIL})
      (?![^.!?\n]*#{STAGED_CLAIM_CONDITIONAL_TAIL})
      (?![^.!?\n]*\?)
    /ix,
    # Explicit change nouns need a confirmation cue. That prevents product-workflow prose such as
    # "the change is staged, reviewed, then applied" from reading as a live proposal.
    /
      #{STAGED_CLAIM_BOUNDARY}
      (?:now\s+)?
      (?:
        (?:the|that|this|your)\s+
          (?:change|update|discount|offer\s+code|product|product\s+update)\s+
          (?:is|has\s+been)
        |
        your\s+(?:changes|updates|discounts)\s+(?:are|have\s+been)
        |
        the\s+requested\s+(?:change|changes|update)\s+
          (?:is|are|has\s+been|have\s+been)
      )
      \s+(?:just\s+|now\s+|been\s+)*staged\b
      (?!#{STAGED_CLAIM_NEGATED_OBJECT})
      (?!#{STAGED_CLAIM_HISTORICAL_TAIL})
      (?!#{STAGED_CLAIM_COMPLETED_TAIL})
      (?:
        (?=[^.!?\n]*#{STAGED_CLAIM_CURRENT_CUE})
        |
        (?=[.!]\s*(?:please\s+)?(?:confirm|approve)\b)
      )
      (?![^.!?\n]*\?)
    /ix,
    # "Staged.", "Staged again", "Staged successfully — confirm below", and the terse production
    # opener.
    /
      #{STAGED_CLAIM_BOUNDARY}
      (?:(?:all|successfully)\s+)?staged(?:\s+(?:now|again|successfully))?\b
      (?!#{STAGED_CLAIM_NEGATED_OBJECT})
      (?!#{STAGED_CLAIM_HISTORICAL_TAIL})
      (?!#{STAGED_CLAIM_COMPLETED_TAIL})
      (?![^.!?\n]*\?)
      (?=\s*(?:\z|[.!]|[—–-]|\band\b|,\s*but\b|
        :\s*(?:please\s+)?(?:confirm|approve)\b|
        ,\s*(?:please\s+)?(?:confirm|approve)\b))
    /ix,
    # The subjectless participle opener, which production produces and the arms above miss because
    # they all need a subject: "Staged deletion of the last draft. Approve it, then...". What the
    # agent staged has to read as the OBJECT of the staging, so a generic sentence subject stays
    # out: "Staged updates wait for your approval" and "Staged deletion of a product is permanent"
    # are prose about the feature, not claims about this turn. Three object shapes qualify — a
    # determiner ("Staged the price change"), a specific "of" complement ("Staged deletion of the
    # draft"), and a bare noun that ends the clause, which no sentence subject can do because a
    # subject is always followed by its verb ("Staged deletion. Approve it").
    #
    # The first two shapes still have to rule the verb out themselves: a determiner is no proof of
    # objecthood, so "Staged deletion of the draft is permanent. Tap the card when you're sure."
    # is feature prose whose following instruction would otherwise complete the match.
    /
      #{STAGED_CLAIM_BOUNDARY}
      staged\s+
      (?:
        (?:the|a|an|your|that|this|two|both)\s+#{STAGED_CLAIM_ACTION_NOUN}\b
          (?!#{STAGED_CLAIM_SUBJECT_PREDICATE})
        |
        #{STAGED_CLAIM_ACTION_NOUN}\s+of\s+(?:the|that|this|your|my)\b
          (?!#{STAGED_CLAIM_SUBJECT_PREDICATE})
        |
        #{STAGED_CLAIM_ACTION_NOUN}
          (?=\s*(?:[.!—–]|\s-\s|
            # A conjoined noun has to end the clause too, or a compound SUBJECT ("Staged changes
            # and updates wait for your approval") reads as an object. That deliberately gives up
            # "Staged deletion and rename of the draft", which the agent has no way to produce
            # while it stages one action per turn.
            and\s+#{STAGED_CLAIM_ACTION_NOUN}\b(?=\s*(?:[.!—–]|\s-\s))))
      )
      (?!#{STAGED_CLAIM_HISTORICAL_TAIL})
      (?!#{STAGED_CLAIM_COMPLETED_TAIL})
      (?![^.!?\n]*#{STAGED_CLAIM_CONDITIONAL_TAIL})
      (?![^.!?\n]*\?)
      (?:
        (?=[^.!?\n]*#{STAGED_CLAIM_CURRENT_CUE})
        |
        (?=[^.!?\n]*[.!]\s*#{STAGED_CLAIM_CARD_INSTRUCTION})
      )
    /ix,
    # Prepared/queued phrasing only counts with an instruction or explicit confirmation purpose in
    # the same sentence. Draft content and explanations can be reviewed without an action card.
    /
      #{STAGED_CLAIM_BOUNDARY}
      (?:now\s+)?
      i(?:['’]ve|\s+have)?\s+(?:just\s+|now\s+)*
      (?:prepared|queued|set\ up|lined\ up)\b
      (?!#{STAGED_CLAIM_NEGATED_OBJECT})
      (?!\s+(?:an?\s+|the\s+|your\s+)?(?:draft\s+(?:email|message)|summary|
        explanation|guide|instructions?|report)\b)
      (?!#{STAGED_CLAIM_HISTORICAL_TAIL})
      (?!#{STAGED_CLAIM_COMPLETED_TAIL})
      [^.!?\n]*
      (?:\bfor\s+(?:your\s+)?(?:confirmation|approval)\b|
        \b(?:please\s+)?(?:confirm|approve)\b|
        \bready\s+(?:for\s+you\s+to\s+(?:confirm|approve)|
          for\s+(?:your\s+)?(?:confirmation|approval))\b)
      (?![^.!?\n]*\?)
    /ix,
    /
      #{STAGED_CLAIM_BOUNDARY}
      (?:
        (?:it|that|this)(?:['’]s|\s+(?:is|has\s+been))
        |
        (?:the|that|this|your)\s+
          (?:change|update|discount|offer\s+code|product|product\s+update)\s+
          (?:is|has\s+been)
      )
      \s+(?:just\s+|now\s+)*(?:prepared|queued|set\ up|lined\ up)\b
      (?!#{STAGED_CLAIM_NEGATED_OBJECT})
      (?!#{STAGED_CLAIM_HISTORICAL_TAIL})
      (?!#{STAGED_CLAIM_COMPLETED_TAIL})
      [^.!?\n]*
      (?:\bfor\s+(?:your\s+)?(?:confirmation|approval)\b|
        \bready\s+(?:for\s+you\s+to\s+(?:confirm|approve)|
          for\s+(?:your\s+)?(?:confirmation|approval))\b)
      (?![^.!?\n]*\?)
    /ix,
    # A bare question ("Ready to confirm?") is not a staging assertion.
    /
      #{STAGED_CLAIM_BOUNDARY}
      (?:
        ready
        |
        (?:
          (?:it|that|this)(?:['’]s|\s+is)
          |
          (?:the|that|this|your)\s+
            (?:change|update|discount|offer\s+code|product|product\s+update)\s+is
        )
        \s+ready
      )
      \s+(?:(?:for\s+you\s+)?to\s+(?:confirm|approve)|
        for\s+(?:your\s+)?(?:confirmation|approval))\b
      (?!#{STAGED_CLAIM_COMPLETED_TAIL})
      (?![^.!?\n]*\?)
    /ix,
    # Fresh/current card assertions are excluded when the sentence describes a conditional workflow
    # or an earlier message instead of a card created for this reply.
    /
      #{STAGED_CLAIM_BOUNDARY}
      (?![^.!?\n]*\b(?:if|when|whenever|once|after|before|would|could)\b)
      (?:a\s+)?(?:fresh|new)\s+confirm(?:ation)?\s+(?:card|button)\b
      [^.!?\n]*\b(?:on\s+this\s+message|below|beneath|underneath)\b
    /ix,
    /
      #{STAGED_CLAIM_BOUNDARY}
      (?![^.!?\n]*\b(?:if|when|whenever|once|after|before|would|could)\b)
      (?:the|a|your)\s+confirm(?:ation)?\s+(?:card|button)\s+
      (?:is|appears|sits)\s+(?:right\s+)?
      (?:below|beneath|underneath|on\s+this\s+message)\b
    /ix,
    /
      #{STAGED_CLAIM_BOUNDARY}
      (?:please\s+)?confirm\s+
      (?:
        (?:it|that|this|the\s+change)\s+(?:below|on\s+the\s+card)
        |
        (?:the|this|that|your)\s+(?:confirmation\s+)?card\s+
          (?:below|beneath|underneath|on\s+this\s+message)
      )\b
      (?![^.!?\n]*\b(?:earlier|previous)\s+message\b)
      (?![^.!?\n]*\?)
    /ix,
  ].freeze

  # How many times we re-ask the model to actually stage the change it claimed to have staged
  # before giving up and telling the creator the truth. One retry is enough in practice and keeps
  # the worst-case turn cost bounded.
  MAX_STAGED_CLAIM_RETRIES = 1
  # The correction itself needs one model turn. If it calls api_write, Anthropic's tool protocol
  # needs one more turn for the final seller-facing reply. Reserve both even when the false claim
  # arrives on the last normal iteration.
  STAGED_CLAIM_RECOVERY_ITERATIONS = 2
  # Fed back to the model when it claimed a staged change without calling api_write, so it can
  # either make the call for real or correct itself. Phrased as the tool-protocol fact it is.
  STAGED_CLAIM_CORRECTION = <<~TEXT.strip
    Your last reply told the creator a change is staged and waiting for their confirmation, but you
    did not call api_write in that reply, so no change was prepared and no confirmation card exists
    for them to click. Call api_write now only if the creator explicitly asked you to prepare or
    re-stage this change. If they only reported a missing card, or did not explicitly ask you to
    re-stage it, do not create another proposal: say plainly that no new change is prepared, ask
    whether they want you to stage it again, and do not refer them to a card.
  TEXT
  # What the creator sees when the model still won't stage the change it keeps claiming to have
  # staged. Better an honest failure they can retry than a confident instruction to click a button
  # that was never rendered. Must not itself match STAGED_CLAIM_PATTERNS above.
  NOTHING_STAGED_REPLY = "That change wasn't prepared, so there's nothing here for you to approve " \
                         "yet. Ask me again and I'll redo it."
  # How many prior turns of context we forward to the model. Keeps token usage bounded and avoids
  # echoing an unbounded client-supplied history back to the model.
  MAX_HISTORY_MESSAGES = 20
  # Cap how many object cards we render inline per turn so a large list can't flood the chat.
  MAX_DISPLAY_OBJECTS = 20
  # How many "what next" follow-up prompts we suggest at the end of a turn to keep the conversation
  # going, and the max length of each so a chip stays a tappable phrase, not a paragraph.
  MAX_SUGGESTIONS = 3
  SUGGESTION_MAX_LENGTH = 80
  MAX_SUGGESTION_TOKENS = 200

  # A tiny separate completion turns the just-finished exchange into a few natural next prompts the
  # creator is likely to want, phrased in their own voice so they read as one-tap continuations.
  FOLLOW_UP_PROMPT = <<~PROMPT.strip
    You suggest what a Gumroad creator might want to ask their store assistant NEXT, to keep the
    conversation going. Given the creator's last message and the assistant's answer, return up to
    three short follow-up prompts.

    Rules:
    - Phrase each as something the CREATOR would say to the assistant, in the first person
      (e.g. "Show my best sellers this month", "Email my customers about it").
    - Keep each under 8 words. No numbering, no quotes, no trailing punctuation.
    - Make them specific and relevant to what was just discussed and to running a store.
    - Return ONLY a JSON array of strings, nothing else. If nothing useful fits, return [].
  PROMPT

  # The system prompt is assembled at runtime (see #system_prompt) so it can embed the live catalog
  # manifest of every endpoint the agent can reach. This keeps the prompt and the actual tool surface
  # from drifting apart as endpoints are added to the catalog.
  SYSTEM_PROMPT_HEADER = <<~PROMPT.strip
    You are Gumroad's store assistant. You help a creator understand and manage their own Gumroad
    store through a chat interface in their dashboard.

    You have two tools that together expose the creator's ENTIRE Gumroad API:
    - api_read: run any READ endpoint to fetch live data (products, sales, payouts, discounts,
      subscribers, upsells, emails, tax forms, earnings, profile, and more). These run immediately.
    - api_write: prepare any change (create/update/delete products, discounts, variants, upsells,
      emails, refunds, shipping, licenses, webhooks, profile, and more). Writes never take effect
      immediately — they produce a proposed change the creator reviews and confirms in the UI.

    To call a tool you pass `endpoint` (one of the ids listed below), `path_params` (the ids the
    endpoint's path needs, e.g. the product id), and `params` (query for reads, body for writes).

    How to act:
    - Be helpful and proactive. If the creator describes a change they want, go ahead and prepare it
      for them with api_write so it's ready to confirm — don't just explain how they could do it
      themselves. Offer to make the change.
    - Only ever act on the current creator's own store. You cannot access other creators' data; the
      API enforces this and an endpoint the creator's role can't use will simply fail.
    - Always use api_read to get real ids and live numbers before acting. Never invent ids.
    - List endpoints are PAGINATED (usually 10 items per page). When a read result includes a
      next_page_key, more items exist: call the same endpoint again with page_key set to that value,
      and keep going until the response has no next_page_key. Any task covering "all" of something
      (all products, all sales, the whole catalog) requires walking every page first. Never state or
      imply you checked items you did not actually fetch — if you can't or didn't fetch a page, say so.
    - Never claim a change has already been made. After api_write, tell the creator you've prepared it
      and it's ready for them to confirm.
    - You cannot see the creator's dashboard. Never invent or describe dashboard screens, settings
      pages, pickers, or menus, and never send the creator to a screen you are not certain exists.
      If a task needs something you have no endpoint for, say so plainly instead of guessing at UI
      directions.
    - Look things up before you rule them out. Gumroad's own documentation is available to you
      through search_help_articles and get_help_article, and it covers far more of the product than
      your tools do. Before you tell the creator that something is not possible, not supported, or
      not customizable, search the help center for it. "I have no endpoint for this" is NEVER the
      same statement as "Gumroad cannot do this" — say the first, never the second, and check the
      docs so you can tell them how it IS done.
    - Some of the store you can't read at all. Your tools cover a large part of Gumroad but not all
      of it, and there is no tool that shows you a rendered page. So when the creator tells you what
      they can see on their own store, believe them: they are looking at it and you are not. Never
      argue with an observation about their own pages, and never invent an explanation for it (a
      "legacy setting", an "older per-product option"). Say you can't see that from here, look it up
      in the help center, and if it's outside what you can read or change, offer to hand it to
      Gumroad support with the details.
    - Store colors and fonts come from the creator's store theme: a background color, a highlight
      (accent) color, and a font. Read them with get_user_theme, which also lists the surfaces they
      cover. They apply to the storefront AND to every product page — product pages ARE themed, so
      never tell a creator their product pages can't be styled. There is no self-serve
      fonts-and-colors screen in the dashboard, and you have no endpoint to change the theme: when
      the creator wants different colors or a different font, say Gumroad support applies those, and
      offer to write down exactly what they want (which color, where) so support can action it. A
      custom HTML page is a separate thing — it brings its own design and does not follow the theme
      — so only reach for it when the creator wants a custom page, not as a workaround for a color
      change.
    - When the creator already has a custom HTML page and asks for a change to it, ALWAYS read the
      current page first and use the targeted edit endpoint to change only the part they asked
      about. Never regenerate or replace an existing page from scratch unless the creator
      explicitly asks for a whole new page — a full replacement destroys everything else on it.
    - When the creator has NO custom HTML page yet and wants a custom page — a layout, structure, or
      imagery the default storefront doesn't give them — author a COMPLETE page with
      update_user_custom_html. A colour or font change is NOT that: colours and fonts are the store
      theme, which support applies, so never author a whole custom page as a way to change a colour.
      Every published page is served with the
      creator's live store data injected into it as a <script id="gumroad-data"
      type="application/json"> element, refreshed on every page load. That JSON holds exactly
      three keys and NOTHING else: products (name, url, price, native_type, thumbnail_url,
      cover_url, description), posts (name, url, published_at), and pages (name). Those are
      the ONLY field names that exist — reading any other name (say a field you'd expect but
      that isn't in this list) gives undefined and renders blank or broken, so never invent
      one. It does NOT contain the
      creator's name, bio, avatar, or any user object — a page that tries to read those from
      the JSON renders them blank. Build the page to READ that JSON and render the product grid
      and links from it, so the storefront stays current as products are added, renamed, or
      removed — never hard-code the product list into the HTML. A product's image is
      thumbnail_url, falling back to cover_url; a product can have neither, so write the card
      to leave the image out entirely in that case rather than emitting an <img> with an empty
      src, which shows a broken-image icon. If the products array is empty,
      render a visible empty state (like "No products yet") so the page still reads as a real
      storefront and not a broken or unfinished page.
    - To put the creator's name and bio on a page, write elements carrying
      data-gumroad-field="name" and data-gumroad-field="bio" (for example
      <h1 data-gumroad-field="name">Store</h1>) — the server replaces their text with the live
      values on every render. That is the ONLY way to show name and bio; they are not in the
      gumroad-data JSON, so scripts cannot look them up. Placeholder text you write inside
      these elements is always overwritten — a blank bio renders as empty text, not your
      placeholder — so style the page to still look right when the bio is empty. Only include
      an avatar, logo, or photo when you have a real Gumroad-hosted image url for it: the
      creator's current avatar is the profile_picture_url that get_user returns, and new
      images go through upload_media. Skip the avatar when profile_picture_url contains
      "gumroad-default-avatar" — that is Gumroad's placeholder for accounts with no uploaded
      picture, served from a host custom pages are not allowed to load images from, so
      embedding it renders a broken image. Never author an empty image slot, and never
      expect an avatar in the gumroad-data JSON — it isn't there.
    - Never publish a page that drops the creator's products or reduces the storefront to a
      colored background.
    - A PRODUCT's landing page (the /l/ page buyers see for one product) is a different surface
      from the profile page, with its own endpoints: get_product_custom_html,
      edit_product_custom_html, and update_product_custom_html. When the creator asks for a landing
      page for one specific product, use those — never the /user profile page endpoints, which
      would overwrite their whole storefront. A published product page replaces the product's
      native page, price and buy button included, so it MUST contain a working buy element like
      <a data-gumroad-action="buy">Buy now</a> — without one, buyers cannot purchase the product.
      Product pages do NOT receive the gumroad-data JSON; instead the server fills elements marked
      data-gumroad-field="name", "price", or "description" with the product's live values on every
      render.
    - Never tell the creator a change is prepared, staged, or waiting for their confirmation unless
      you actually called api_write in this same reply. If the creator agrees to go ahead and
      nothing is staged yet, that is your cue to call api_write now — not to ask for confirmation
      again.
    - If the creator says they cannot see a confirmation card or button, believe them. Never send
      them back to an earlier message or claim the card is already there — you cannot see their
      screen. Explain that no change can apply without a visible confirmation, and ask whether they
      want you to stage it again. Only call api_write again after they explicitly ask you to
      re-stage it; blindly creating a second proposal can leave two copies of an action that is
      unsafe to run twice waiting to be confirmed.
    - Custom HTML pages only display images hosted by Gumroad — external file
      urls are blocked by the page's security policy and render broken. When the creator wants
      their image (logo, photo, banner) on a page, first upload it with
      upload_media (they give you the file's url), then embed the HOSTED url it returns in the
      page HTML. Never embed an external image url directly in a page. If they haven't given a
      url, ask them for a link to the file.
    - Prepare at most one change per reply. If the creator asks for several, do the first and tell
      them you'll continue once they confirm.
    - Monetary amounts in the API are in CENTS (integer). $10 = 1000.

    How to write:
    - Write like a person: warm, plain, and direct. Short sentences. No corporate filler.
    - Do not use emoji.
    - Do not use markdown headers, bold, bullet characters, tables, or other decorative formatting.
      Just write normal sentences. Products, discounts, and other objects you look up or change are
      shown to the creator automatically as cards beneath your message, so don't re-list their
      details or paste links in the text — refer to them by name and keep your reply brief.
    - Don't mention other people, teammates, or @-handles.

    READ endpoints (api_read):
    %<reads>s

    WRITE endpoints (api_write — each requires confirmation):
    %<writes>s
  PROMPT

  ProposedAction = Struct.new(:type, :params, :summary, :title, :fields, keyword_init: true) do
    # `title` names the operation (the endpoint's own summary) so the card always states what will
    # happen — important for destructive writes. `fields` are humanized detail rows; `summary` is the
    # one-line fallback the card shows when there are no fields.
    def as_json(*) = { type:, params:, summary:, title:, fields: fields || [] }
  end

  def initialize(seller:, pundit_user:)
    @seller = seller
    @pundit_user = pundit_user
  end

  # @param messages [Array<Hash>] prior conversation, each { role: "user"|"assistant", content: String }
  # @return [Hash] { reply: String, proposed_action: Hash|nil, objects: Array<Hash> }
  def respond(messages:)
    conversation = build_conversation(messages)
    proposed_action = nil
    # Display objects collected from the read calls this turn, rendered inline as cards in the chat.
    @objects = []
    staged_claim_retries = 0

    remaining_iterations = MAX_TOOL_ITERATIONS
    while remaining_iterations.positive?
      remaining_iterations -= 1
      result = client.messages(
        system: system_prompt,
        messages: conversation,
        tools: tool_schemas,
        max_tokens: MAX_REPLY_TOKENS,
      )

      # The model hit MAX_REPLY_TOKENS mid-turn. Whatever came back is incomplete — a cut-off tool
      # call has unusable arguments, and a cut-off text answer would read as a complete reply when
      # it isn't — so stop here with an honest message instead of acting on a truncated turn.
      if result.stop_reason == "max_tokens"
        return { reply: TRUNCATED_REPLY, proposed_action: proposed_action&.as_json, objects: deduped_objects }
      end

      if result.tool_uses.blank?
        reply = result.text.to_s.strip

        # The reply claims a change is staged but nothing was: there is no card to confirm, so the
        # claim is false. Re-ask the model to actually stage it; if it still won't, tell the
        # creator the truth rather than sending them after a button that does not exist.
        if phantom_staged_claim?(reply:, proposed_action:)
          if staged_claim_retries < MAX_STAGED_CLAIM_RETRIES
            staged_claim_retries += 1
            remaining_iterations = [remaining_iterations, STAGED_CLAIM_RECOVERY_ITERATIONS].max
            log_phantom_staged_claim(retrying: true)
            append_staged_claim_correction(conversation, reply)
            next
          end

          log_phantom_staged_claim(retrying: false)
          return { reply: NOTHING_STAGED_REPLY, proposed_action: nil, objects: deduped_objects }
        end

        return { reply:, proposed_action: proposed_action&.as_json, objects: deduped_objects }
      end

      proposed_action = apply_tool_uses(text: result.text, tool_uses: result.tool_uses, conversation:, proposed_action:)
    end

    { reply: tool_cap_reply(proposed_action), proposed_action: proposed_action&.as_json, objects: deduped_objects }
  end

  # Streaming counterpart of #respond. Runs the same read/propose tool loop, but streams the final
  # assistant reply token-by-token and, once the answer is complete, suggests a few follow-up prompts
  # to keep the conversation going. Communicates by yielding [event, payload] pairs the controller
  # writes to the client as Server-Sent Events:
  #   [:token, { text: }]                 — a chunk of the reply text, as it arrives
  #   [:objects, { objects: }]            — object cards looked up/changed this turn
  #   [:proposed_action, { proposed_action: }] — a single staged change awaiting confirmation
  #   [:suggestions, { suggestions: }]    — up to three "what next" prompts
  # Returns the same hash shape as #respond (plus :suggestions) once the stream is complete.
  #
  # `on_reply_complete` (optional) is invoked with { reply:, proposed_action:, objects: } the
  # moment the reply is final — BEFORE any trailing event is written to the (possibly already
  # dead) client socket and before the extra follow-up-suggestions LLM call. Callers use it to
  # persist the turn: if the client's connection died mid-stream, the very next socket write
  # raises ClientDisconnected, and without this hook a fully generated reply would be discarded
  # unpersisted — the seller watched it stream in, but no record of it survives.
  def respond_streaming(messages:, on_reply_complete: nil, &emit)
    conversation = build_conversation(messages)
    last_user_message = conversation.reverse.find { |m| m[:role] == "user" }&.dig(:content).to_s
    proposed_action = nil
    @objects = []
    staged_claim_retries = 0

    remaining_iterations = MAX_TOOL_ITERATIONS
    while remaining_iterations.positive?
      remaining_iterations -= 1
      # Stream this turn's text deltas live. We don't yet know if the turn is final (text-only) or an
      # intermediate tool-use turn that happens to include preamble text, so track whether anything
      # was streamed: if the turn turns out to be a tool-use turn, we emit :reset to discard its
      # preamble from the UI, and only the final (tool_uses-blank) turn's text survives on screen.
      streamed_any = false
      result = client.stream_messages(
        system: system_prompt,
        messages: conversation,
        tools: tool_schemas,
        max_tokens: MAX_REPLY_TOKENS,
        # A corrupted tool call is recovered by replaying the turn without streaming, which
        # regenerates the reply from the start. Tool-use turns usually stream a sentence of
        # preamble first, so without a way to clear it that recovery could never run — the client
        # refuses to replay over text the seller can still see. This is the same :reset the normal
        # tool-use path below uses to discard preamble, so the seller ends up in the identical
        # state: an empty transcript that the recovered turn then fills in.
        on_discard_streamed_text: -> {
          emit.call(:reset, {}) if streamed_any
          streamed_any = false
        },
      ) do |text|
        streamed_any = true
        emit.call(:token, { text: })
      end

      # Same truncation handling as #respond. Anything this turn streamed is incomplete, so tell
      # the UI to discard it and stream the honest fallback instead of leaving half an answer (or
      # half a tool call's preamble) on screen as if it were the finished reply.
      if result.stop_reason == "max_tokens"
        emit.call(:reset, {}) if streamed_any
        emit.call(:token, { text: TRUNCATED_REPLY })
        return finish_stream(reply: TRUNCATED_REPLY, proposed_action:, last_user_message:, emit:, on_reply_complete:)
      end

      if result.tool_uses.blank?
        reply = result.text.to_s.strip

        # Same phantom-staging guard as #respond. The claim already streamed to the seller, so tell
        # the UI to discard it before either replaying the turn (the model gets one chance to
        # actually call api_write) or streaming the honest "nothing staged" line — otherwise the
        # false claim stays on screen next to a card that will never appear.
        if phantom_staged_claim?(reply:, proposed_action:)
          if staged_claim_retries < MAX_STAGED_CLAIM_RETRIES
            emit.call(:reset, {}) if streamed_any
            staged_claim_retries += 1
            remaining_iterations = [remaining_iterations, STAGED_CLAIM_RECOVERY_ITERATIONS].max
            log_phantom_staged_claim(retrying: true)
            append_staged_claim_correction(conversation, reply)
            next
          end

          log_phantom_staged_claim(retrying: false)
          return finish_stream(
            reply: NOTHING_STAGED_REPLY,
            proposed_action: nil,
            last_user_message:,
            emit:,
            on_reply_complete:,
          ) do
            # Persist the final fallback before either socket write. A disconnect here must not lose
            # a fully determined turn; exact-turn recovery can then adopt the stored honest reply.
            emit.call(:reset, {}) if streamed_any
            emit.call(:token, { text: NOTHING_STAGED_REPLY })
          end
        end

        return finish_stream(reply:, proposed_action:, last_user_message:, emit:, on_reply_complete:)
      end

      # Intermediate tool-use turn: any text it streamed was preamble, not the answer. Tell the UI to
      # clear it so the seller never sees an interim claim that gets replaced by the real reply.
      emit.call(:reset, {}) if streamed_any
      proposed_action = apply_tool_uses(text: result.text, tool_uses: result.tool_uses, conversation:, proposed_action:)
    end

    # Hit the tool-iteration cap. Stream the fallback line as a single token so the UI still renders a
    # reply, then close out with the same objects/action/suggestions as a normal turn.
    reply = tool_cap_reply(proposed_action)
    emit.call(:token, { text: reply })
    finish_stream(reply:, proposed_action:, last_user_message:, emit:, on_reply_complete:)
  end

  private
    attr_reader :seller, :pundit_user

    # Echo the assistant's tool-use turn back into the conversation, run each requested tool, and
    # append a single user message carrying the tool_result blocks (the Anthropic tool-use protocol).
    # Returns the (possibly updated) proposed action. Shared by #respond and #respond_streaming so the
    # two paths can't drift.
    def apply_tool_uses(text:, tool_uses:, conversation:, proposed_action:)
      # The assistant turn must replay both any text it produced AND the tool_use blocks, in order.
      assistant_content = []
      assistant_content << { type: "text", text: text.to_s } if text.to_s.strip.present?
      tool_uses.each do |tool_use|
        assistant_content << { type: "tool_use", id: tool_use[:id], name: tool_use[:name], input: tool_use[:input] || {} }
      end
      conversation << { role: "assistant", content: assistant_content }

      tool_results = tool_uses.map do |tool_use|
        arguments = sanitize_param_hash(tool_use[:input])
        result, action = run_tool(name: tool_use[:name], arguments:)
        if action.present?
          if proposed_action.nil?
            proposed_action = action
          else
            # Only one change may be staged per turn. If the model proposes a second write in the
            # same turn we drop it and tell the model, so the confirmation card can never describe a
            # different mutation than the one the seller sees and confirms.
            result = { error: "Only one change can be proposed at a time. Ask the seller to confirm the first change before proposing another." }
          end
        end
        { type: "tool_result", tool_use_id: tool_use[:id], content: result.to_json }
      end
      conversation << { role: "user", content: tool_results }

      proposed_action
    end

    # True when the finished reply tells the creator a change is staged and waiting for their
    # confirmation while no proposed action exists for this turn. The confirmation card is rendered
    # purely from the proposed action, so in that state the creator is told to click a button that
    # was never created — the failure this guard exists for.
    def phantom_staged_claim?(reply:, proposed_action:)
      return false if proposed_action.present?
      return false if reply.blank?
      # The patterns are alternation-heavy and scan the whole reply, so cost grows with length.
      # No claim can match without one of these stems, and the check is a single linear pass, so
      # it keeps a long reply from paying for every pattern. "approv" rather than "approve"
      # because the phrasing that carries no other stem is "for your approval".
      return false unless reply.match?(/\b(?:staged|prepared|queued|confirm|approv|ready)/i)

      # A reply can quote an earlier assistant message before giving its current answer. Remove only
      # that attributed clause; a later current claim in the same reply still goes through the guard.
      candidate = reply.gsub(
        /\b(?:the\s+)?(?:earlier|previous)\s+(?:reply|message)\s+
          (?:said|claimed|read)\s*:\s*[^.!?;\n]*/ix,
        "",
      )
      STAGED_CLAIM_PATTERNS.any? { |pattern| candidate.match?(pattern) }
    end

    # Replay the model's own false claim back at it as an assistant turn, followed by a user turn
    # stating the tool-protocol fact, so the next iteration can either call api_write for real or
    # correct itself. Using the normal message roles (rather than mutating the system prompt) keeps
    # the correction visible in exactly the place the model reads context from.
    def append_staged_claim_correction(conversation, reply)
      conversation << { role: "assistant", content: reply }
      conversation << { role: "user", content: STAGED_CLAIM_CORRECTION }
    end

    # Before this, a phantom staging claim was invisible outside a database read: no metric, no log
    # line, nothing to alert on. Log and report it so the rate is trackable and a regression shows up
    # without anyone querying ai_messages by hand.
    def log_phantom_staged_claim(retrying:)
      outcome = retrying ? "retrying" : "gave up, told the seller nothing was prepared"
      Rails.logger.warn("Store agent claimed a staged change with no proposed action (#{outcome})")
      # Report BOTH the retry and the give-up under one fixed message string so every occurrence
      # groups as a single Sentry issue. Reporting only the give-up would hide every recovered turn.
      ErrorNotifier.notify(
        "Store agent claimed a staged change with no proposed action",
        outcome:,
      )
    end

    # The model kept calling tools past our cap. Return a message that matches reality: only mention
    # confirmation when there is actually a proposed action to confirm.
    def tool_cap_reply(proposed_action)
      if proposed_action
        "I gathered the details but need you to confirm the next step before I continue."
      else
        "I gathered the details but couldn't finish in one go. Please rephrase or ask again."
      end
    end

    # Emit the trailing events for a completed streaming turn (objects, any staged change, and the
    # follow-up suggestions) and return the full result hash. The on_reply_complete hook fires
    # first — before any further socket write — so the caller can persist the finished turn even
    # when the client's connection is already dead (the next emit would raise ClientDisconnected
    # and abandon the turn) and before the seller waits out the extra suggestions LLM call.
    def finish_stream(reply:, proposed_action:, last_user_message:, emit:, on_reply_complete: nil, &before_trailing_events)
      objects = deduped_objects
      result = { reply:, proposed_action: proposed_action&.as_json, objects: }
      on_reply_complete&.call(result)
      before_trailing_events&.call
      emit.call(:objects, { objects: }) if objects.any?
      emit.call(:proposed_action, { proposed_action: proposed_action.as_json }) if proposed_action
      suggestions = follow_up_suggestions(reply:, last_user_message:)
      emit.call(:suggestions, { suggestions: }) if suggestions.any?
      result.merge(suggestions:)
    end

    # Ask the model for a few short, in-voice next prompts based on the turn that just happened. Kept
    # deliberately cheap (no tools, low max_tokens) and fully best-effort: any failure or unparseable
    # output yields no suggestions rather than breaking the reply the creator already received.
    def follow_up_suggestions(reply:, last_user_message:)
      return [] if reply.blank?

      result = client.messages(
        system: FOLLOW_UP_PROMPT,
        messages: [
          { role: "user", content: "The creator said: #{last_user_message}\n\nYou answered: #{reply}\n\nSuggest up to three follow-up prompts." },
        ],
        max_tokens: MAX_SUGGESTION_TOKENS,
      )
      parse_suggestions(result.text)
    rescue => e
      Rails.logger.warn("Store agent follow-up suggestions failed: #{e.message}")
      []
    end

    # Coerce the model's reply into a clean list of suggestion strings. Prefers a JSON array but
    # tolerates a newline/dash list, then trims, de-dupes, drops blanks, and caps count + length.
    def parse_suggestions(raw)
      text = raw.to_s.strip
      return [] if text.blank?

      parsed = (JSON.parse(text) rescue nil)
      items =
        if parsed.is_a?(Array)
          parsed
        else
          text.split("\n").map { |line| line.sub(/\A\s*(?:[-*\d.)\s]+)/, "") }
        end

      items
        .map { |item| item.to_s.strip.delete_prefix('"').delete_suffix('"').strip }
        .reject(&:blank?)
        .map { |item| item.truncate(SUGGESTION_MAX_LENGTH) }
        .uniq
        .first(MAX_SUGGESTIONS)
    end

    # De-duplicate the collected objects (the model may read the same list twice in one turn) while
    # preserving order, and cap how many cards we render so a huge list can't flood the chat.
    def deduped_objects
      Array(@objects).uniq.first(MAX_DISPLAY_OBJECTS)
    end

    # Build the Anthropic message array from the client-supplied history. The system prompt is passed
    # separately (Anthropic's top-level `system` param), so it is NOT included here.
    def build_conversation(messages)
      history = Array(messages).last(MAX_HISTORY_MESSAGES).filter_map do |msg|
        role = msg[:role] || msg["role"]
        content = (msg[:content] || msg["content"]).to_s.strip
        next if content.blank?
        next unless %w[user assistant].include?(role)

        { role:, content: content.truncate(MAX_MESSAGE_LENGTH, omission: "...") }
      end

      # Anthropic's Messages API requires the conversation to START with a user message. The web chat
      # always opens with a canned assistant greeting (and a turn could begin with other leading
      # assistant turns), so drop any leading assistant messages before the first user message.
      history = history.drop_while { |m| m[:role] != "user" }
      raise Error, "Message is required" if history.empty? || history.last[:role] != "user"

      history
    end

    # Assemble the system prompt with the live read/write endpoint manifests embedded, so the model
    # is told exactly which endpoint ids exist and what each does.
    def system_prompt
      format(
        SYSTEM_PROMPT_HEADER,
        reads: Ai::StoreAgentApiCatalog.manifest(:read),
        writes: Ai::StoreAgentApiCatalog.manifest(:write),
      )
    end

    # Two generic tools drive the whole catalog. `api_read` runs a read endpoint immediately;
    # `api_write` turns a write endpoint into a single proposed action (never mutates here).
    def run_tool(name:, arguments:)
      case name
      when "api_read" then run_api_read(arguments)
      when "api_write" then propose_api_write(arguments)
      else
        [{ error: "Unknown tool: #{name}" }, nil]
      end
    end

    # ---- api_read: auto-executed, creator-scoped via the real v2 API ----

    def run_api_read(arguments)
      endpoint = Ai::StoreAgentApiCatalog.find(arguments["endpoint"])
      if endpoint.nil?
        return [{ error: "Unknown endpoint. Use one of the read endpoint ids listed for api_read." }, nil]
      end
      unless endpoint.read?
        # A write id was sent to the read tool. Don't run it (that would mutate without confirmation);
        # tell the model to use api_write so it goes through the confirmation card.
        return [{ error: "#{endpoint.id} changes data — use api_write so the creator can confirm it." }, nil]
      end
      unless endpoint_permitted?(endpoint)
        # Defense in depth: the minted token's scopes already exclude this, so the API would 403, but
        # refusing here avoids a wasted dispatch and gives the model a clear reason.
        return [{ error: "The current user's role can't access #{endpoint.id}." }, nil]
      end

      path = endpoint.expand_path(arguments["path_params"])
      result = api_client.get(path, sanitize_param_hash(arguments["params"]))
      # Collect any renderable objects from the response so the chat can show them inline as cards.
      @objects.concat(Ai::StoreAgentObjectFormatter.from_response(endpoint, result)) if @objects
      [result, nil]
    rescue ArgumentError => e
      # Missing/blank path param (e.g. the model forgot the product id).
      [{ error: e.message }, nil]
    end

    # ---- api_write: returns a proposed action; never mutates ----

    def propose_api_write(arguments)
      endpoint = Ai::StoreAgentApiCatalog.find(arguments["endpoint"])
      if endpoint.nil?
        return [{ error: "Unknown endpoint. Use one of the write endpoint ids listed for api_write." }, nil]
      end
      unless endpoint.write?
        # A read id was sent to the write tool. Reads never need confirmation; nudge the model to use
        # api_read instead so it gets the data immediately.
        return [{ error: "#{endpoint.id} only reads data — use api_read to get it immediately." }, nil]
      end
      unless endpoint_permitted?(endpoint)
        # Defense in depth: don't even stage a proposal the acting user's role can't execute, so the
        # seller never sees a confirmation card for a change that would 403 on confirm.
        return [{ error: "The current user's role can't perform #{endpoint.id}." }, nil]
      end

      path_params = sanitize_param_hash(arguments["path_params"])
      body = sanitize_param_hash(arguments["params"])
      # Validate the path can actually be built now (so the confirmation card never describes a call
      # that would fail on a missing id at execute time).
      begin
        endpoint.expand_path(path_params)
      rescue ArgumentError => e
        return [{ error: e.message }, nil]
      end

      # Refuse to stage a body carrying keys the endpoint doesn't declare. The v2 API silently
      # ignores unknown body keys, so without this check a write like create_product with
      # "price_cents" (instead of the declared "price") sails through to the API missing its real
      # payload, fails there with a confusing internal error, and the model retries the same wrong
      # key forever. Naming the unknown and allowed keys here lets the model correct itself within
      # the same turn instead of doom-looping.
      if (error = unknown_body_keys_error(endpoint, body))
        return [{ error: }, nil]
      end

      summary = write_summary(endpoint, path_params, body)
      action = ProposedAction.new(
        type: "api_write",
        # Everything the executor needs to replay the exact same call after the creator confirms.
        params: { "endpoint" => endpoint.id, "path_params" => path_params, "params" => body },
        summary:,
        # The operation itself (e.g. "Delete a discount code."), shown as the card's heading.
        title: endpoint.summary,
        fields: write_fields(endpoint, path_params, body),
      )
      [{ proposed: true, summary: }, action]
    end

    # A human-readable description of the pending change for the confirmation card. Built from the
    # catalog summary plus the concrete ids/params so the creator sees exactly what will happen.
    def write_summary(endpoint, path_params, body)
      parts = [endpoint.summary]
      detail = path_params.merge(body).map { |k, v| "#{k}: #{v}" }.join(", ")
      parts << "(#{detail})" if detail.present?
      parts.join(" ")
    end

    # Friendlier labels for a couple of offer-code body keys; everything else is humanized generically.
    OFFER_CODE_LABELS = { "name" => "Code", "max_purchase_count" => "Max uses" }.freeze
    # Shown for a body key the model set to blank/null, so a "clear this field" mutation stays visible
    # rather than silently dropping off the card while still executing.
    BLANK_VALUE = "(blank)"

    # Humanized label/value rows for the confirmation card. EVERY path param and body key is
    # represented, so the card never hides a proposed mutation or the record it targets. A few are
    # rendered nicely — the discount amount + type as one row, cents as currency, and product ids as
    # names — but nothing is dropped. Values are coerced to strings (non-scalar tool output is
    # JSON-encoded rather than formatted), so a hallucinated array/object can't raise here.
    def write_fields(endpoint, path_params, body)
      body = body.dup
      offer_code = endpoint.id.include?("offer_code")
      product = target_product(endpoint, path_params)
      # Amounts apply in the target resource's currency. Use the product's; for a new product fall back
      # to the requested or seller currency; leave it unknown elsewhere (e.g. a sale's currency on a
      # refund) so we never stamp a wrong symbol on the card.
      # The currency amounts will actually save in. Only product create/update persist a requested
      # price_currency_type, so only honor it there (a discount/refund ignores it and uses the product
      # or sale currency); then the existing product's, the seller's for a brand-new product, else
      # unknown (e.g. a sale on a refund) so we don't stamp a wrong symbol.
      honors_requested_currency = endpoint.id.in?(%w[create_product update_product])
      currency = (honors_requested_currency ? requested_currency(body) : nil) ||
                 product&.price_currency_type ||
                 (seller.currency_type if endpoint.id == "create_product")

      # Target identity (path params are validated non-blank) — names the record being changed.
      rows = path_params.filter_map { |key, value| preview_field(path_label(endpoint, key), path_value(endpoint, key, value, product)) }

      # Body keys are intentional mutations, so each gets a row even when blank (a blank renders as
      # "(blank)") — otherwise a destructive clear like description: "" would execute invisibly. The
      # discount amount + type collapse into one readable row; both are still represented.
      if body.key?("amount_off") || body.key?("offer_type")
        rows << { label: "Discount", value: discount_amount(body.delete("amount_off"), body.delete("offer_type"), currency).presence || BLANK_VALUE }
      end
      body.each { |key, value| rows << { label: field_label(key, offer_code:), value: display_value(key, value, currency).presence || BLANK_VALUE } }
      rows << { label: "Max uses", value: "Unlimited" } if endpoint.id == "create_offer_code" && !body.key?("max_purchase_count")

      rows
    end

    def path_label(endpoint, key)
      return "Applies to" if key.to_s == "link_id"
      return "Product" if key.to_s == "id" && endpoint.id.include?("product")
      return "Discount code" if key.to_s == "id" && endpoint.id.include?("offer_code")
      key.to_s.humanize
    end

    # A path id displays as "name (id)" when it points at a resolvable product — the name for the
    # seller to recognize, the raw id (which is what's replayed) so a destructive write still names the
    # exact record even when two products share a name. Otherwise it's just the id.
    def path_value(endpoint, key, value, product)
      points_at_product = key.to_s == "link_id" || (key.to_s == "id" && endpoint.id.include?("product"))
      name = product&.name if points_at_product
      name.present? ? "#{name} (#{value})" : display_value(key, value)
    end

    def field_label(key, offer_code:)
      (offer_code && OFFER_CODE_LABELS[key.to_s]) || key.to_s.humanize
    end

    # Cents keys -> currency when known (else the raw integer, so we never imply the wrong currency);
    # description -> truncated; non-scalar (untrusted) -> JSON; else a string.
    def display_value(key, value, currency = nil)
      return nil if value.nil?
      return value.to_json unless value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      case key.to_s
      when "price", "amount_cents", "minimum_amount_cents"
        # Format real cents in the currency's own subunit (JPY has none, so 1000 -> ¥1,000, not ¥10).
        # Anything that isn't a number/digit-string — a blank, a boolean, or a hallucinated "free" —
        # shows raw (and blanks become "(blank)" via the caller), so the card never coerces a non-amount
        # into $0 or implies a wrong amount.
        currency && numeric_cents?(value) ? MoneyFormatter.format(value.to_i, currency, no_cents_if_whole: true) : value.to_s
      else
        # Show the full value — this is the safety boundary, so never truncate what will be applied.
        value.to_s
      end
    end

    # "20% off" for a percentage code; for a fixed-amount one the value is cents in the target's
    # currency. Non-scalar (untrusted) input is JSON-encoded rather than formatted, so a hallucinated
    # object can't raise; a non-numeric or unknown-currency amount shows raw rather than a wrong symbol.
    def discount_amount(amount, offer_type, currency)
      return nil if amount.nil?
      return amount.to_json unless amount.is_a?(String) || amount.is_a?(Numeric)
      return nil if amount.to_s.strip.blank?
      return "#{amount}% off" if offer_type.to_s == "percent"
      return amount.to_s unless numeric_cents?(amount)
      formatted = currency ? MoneyFormatter.format(amount.to_i, currency, no_cents_if_whole: true) : amount.to_s
      "#{formatted} off" if formatted.present?
    end

    # A value we can safely render as money: a number, or a string of digits (cents). Anything else
    # (a blank, a hallucinated "free") is shown raw instead of coercing to $0.
    def numeric_cents?(value)
      value.is_a?(Numeric) || (value.is_a?(String) && value.match?(/\A-?\d+\z/))
    end

    # The seller's product for the write's path id (external id or permalink), or nil. Names the target
    # and supplies the currency the confirmed amounts will use. One cheap lookup, only when proposing.
    def target_product(endpoint, path_params)
      external_id = path_params["link_id"] || (endpoint.id.include?("product") ? path_params["id"] : nil)
      return nil if external_id.to_s.strip.blank?
      seller.links.find_by_external_id(external_id) || seller.links.find_by(unique_permalink: external_id)
    end

    # A valid currency this write itself sets (product writes accept price_currency_type), or nil.
    # Guards an invalid/untrusted value from reaching the formatter.
    def requested_currency(body)
      requested = body["price_currency_type"].to_s.downcase.presence
      requested if CURRENCY_CHOICES.key?(requested)
    end

    def preview_field(label, value)
      stringified = value.to_s.strip
      { label:, value: stringified } if stringified.present?
    end

    # Tool-call inputs are supposed to be JSON objects; a hallucinating model can emit an array or
    # scalar (or, for a nested key, a non-hash). Coerce anything that isn't a Hash to an empty hash,
    # and stringify keys, so downstream indexing/path-expansion can't raise a TypeError as a 500.
    def sanitize_param_hash(raw)
      return {} unless raw.is_a?(Hash)
      raw.transform_keys(&:to_s)
    end

    # A corrective message when the proposed body carries keys the endpoint doesn't declare, or nil
    # when the body is fine. Delegates to the catalog Endpoint so this propose-path message and the
    # executor's confirm-path message can't drift apart.
    def unknown_body_keys_error(endpoint, body)
      endpoint.unknown_param_keys_error(body)
    end

    def api_client
      @_api_client ||= Ai::StoreAgentApiClient.new(seller:, pundit_user:)
    end

    # True if the acting user's role may drive this endpoint. Requires the role to carry the
    # endpoint's scope AND, for endpoints the dashboard restricts to admins beyond their OAuth scope
    # (admin_only?, e.g. webhook management), the acting user to be an owner/admin. Mirrors the token
    # narrowing so a read/proposal the API or our role boundary would refuse is rejected up front.
    def endpoint_permitted?(endpoint)
      return false if endpoint.admin_only? && !admin_or_owner?
      endpoint.scope.blank? || permitted_scopes.include?(endpoint.scope)
    end

    def admin_or_owner?
      user = pundit_user&.user
      seller = pundit_user&.seller
      user.present? && seller.present? && user.role_admin_for?(seller)
    end

    def permitted_scopes
      @_permitted_scopes ||= Ai::StoreAgentScopes.permitted_for(pundit_user)
    end

    def client
      @_client ||= Ai::AnthropicClient.new(timeout: REQUEST_TIMEOUT_IN_SECONDS, model: MODEL)
    end

    # Two generic tools. The endpoint id (constrained to the catalog by an enum) selects which of the
    # ~60 real API endpoints to hit; path_params/params carry the ids and payload. Keeping the schema
    # this small avoids a 60-function tool list while still reaching the entire API. Anthropic tool
    # schemas use `input_schema` (JSON Schema) instead of OpenAI's `function.parameters`.
    def tool_schemas
      [
        tool_schema(
          "api_read",
          "Read live data from the creator's Gumroad store by calling a READ API endpoint. Runs immediately.",
          {
            endpoint: { type: "string", enum: Ai::StoreAgentApiCatalog.read_ids, description: "Which read endpoint to call (see the READ endpoints list)." },
            path_params: { type: "object", description: "Ids the endpoint's path needs, e.g. {\"id\": \"<product id>\"}. Omit if none.", additionalProperties: { type: "string" } },
            params: { type: "object", description: "Query parameters, e.g. {\"after\": \"2024-01-01\"}. Omit if none." },
          },
          required: ["endpoint"],
        ),
        tool_schema(
          "api_write",
          "PROPOSE a change to the creator's store by calling a WRITE API endpoint. Does NOT take effect until the creator confirms. Propose only one change per reply.",
          {
            endpoint: { type: "string", enum: Ai::StoreAgentApiCatalog.write_ids, description: "Which write endpoint to call (see the WRITE endpoints list)." },
            path_params: { type: "object", description: "Ids the endpoint's path needs, e.g. {\"id\": \"<product id>\"}. Omit if none.", additionalProperties: { type: "string" } },
            params: { type: "object", description: "Request body. Monetary amounts are in cents (integer). Omit if none." },
          },
          required: ["endpoint"],
        ),
      ]
    end

    def tool_schema(name, description, properties, required: [])
      {
        name:,
        description:,
        input_schema: { type: "object", properties:, required: },
      }
    end
end
