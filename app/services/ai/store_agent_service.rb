# frozen_string_literal: true

# Ai::StoreAgentService powers the conversational "Agent" dashboard tab. The seller chats with an
# assistant that can answer questions about their store and *propose* changes to it.
#
# The agent runs on Grok 4.5 via OpenRouter's Anthropic-compatible endpoint (see MODEL below), with
# Claude Opus 4.7 — its previous production model — as the request-level fallback when Grok errors.
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
  # Grok is only reachable through OpenRouter, so the cutover keys off routing: a direct-Anthropic
  # config keeps serving Opus unchanged (gumroad-private#1879).
  OPENROUTER_MODEL = "x-ai/grok-4.5"
  # When Grok errors (provider down, rate limited), OpenRouter retries the turn on the agent's
  # previous production model rather than the client's default GPT fallback.
  OPENROUTER_FALLBACK_MODEL = "anthropic/claude-opus-4.7"
  # Per-seller ramp (gumroad-private#1879). Below 100% this decides Grok vs Opus per seller in
  # addition to OPENROUTER_API_KEY being configured; at 100% and once the flag is deleted the
  # OpenRouter-configured check alone will govern, per the issue's cleanup plan.
  GROK_RAMP_FEATURE = :store_agent_grok
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
  # History budget per PRIOR message, so twenty turns of recap cannot crowd out the system prompt.
  MAX_MESSAGE_LENGTH = 2_000
  # The turn being answered gets its own budget: it is the request, not a recap, and trimming it
  # drops the instructions the model needs. Gumroad's own Share tab → Landing page → "Copy prompt"
  # emits ~4,900 characters, so at the history budget every creator who pasted it lost most of it
  # before the model saw it and was told the request was too large.
  MAX_CURRENT_MESSAGE_LENGTH = 20_000
  MISSING_REQUIRED_READ_MESSAGE = "Store agent write proposal blocked by missing required full read"
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
  STAGED_CLAIM_HISTORICAL_TAIL = /
    (?:
      \s+(?:(?:it|that|this)|(?:the|that|this|your)\s+
        (?:change|update|discount|offer|code|edit))?\s*
      (?:yesterday|previously|earlier|before|many\s+times|
        last\s+(?:night|week|month|year)|in\s+the\s+past)\b
      |
      \s+(?:(?:it|that|this)\s+)?(?:on|in)\s+(?:my|the)\s+
        (?:earlier|previous)\s+message\b
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
  # Two subjectless forms survived the original guard in production: a bounded action followed by
  # a card instruction, and "Staged again" followed by a replacement-card instruction. Keep this
  # grammar anchored to the whole reply and to the measured action shapes. Widening it into a noun
  # phrase parser would make explanatory or quoted prose eligible for destructive replacement.
  STAGED_CLAIM_SUBJECTLESS_DETAIL = /
    (?>[[:blank:]]*)
    \((?>[-[:alnum:]&+'’]+),(?>[[:blank:]]*)
    \$[[:digit:]][[:digit:],]*(?:\.[[:digit:]]{1,2})?\)
  /x
  STAGED_CLAIM_SUBJECTLESS_ACTION = /
    (?:
      deletion(?>[[:blank:]]+)of(?>[[:blank:]]+)
      (?:the|a|an|your)(?>[[:blank:]]+)
      (?:last(?>[[:blank:]]+))?
      (?:(?>[-[:alnum:]#$%&+'’]+)(?>[[:blank:]]+))?
      draft\b
      (?:#{STAGED_CLAIM_SUBJECTLESS_DETAIL})?
      |
      removal(?>[[:blank:]]+)of(?>[[:blank:]]+)
      (?:the|a|an|your)(?>[[:blank:]]+)
      (?:duplicate(?>[[:blank:]]+))?
      (?:mobile(?>[[:blank:]]+))?
      block\b
      (?:#{STAGED_CLAIM_SUBJECTLESS_DETAIL})?
      |
      the(?>[[:blank:]]+)price(?>[[:blank:]]+)change\b
    )
  /ix
  STAGED_CLAIM_SUBJECTLESS_LIVE_TAIL = /
    (?>[[:blank:]]+)and(?>[[:blank:]]+)
    (?:it|that|this|the(?>[[:blank:]]+)archive)
    (?>[[:blank:]]+)(?:goes|becomes)(?>[[:blank:]]+)live
  /ix
  STAGED_CLAIM_SUBJECTLESS_CARD_INSTRUCTION = /
    (?:please(?>[[:blank:]]+))?
    (?:approve|confirm|tap|click|hit|press)(?>[[:blank:]]+)
    (?:on(?>[[:blank:]]+))?
    (?:
      it|that|this
      |
      (?:the|that|this|your)(?>[[:blank:]]+)
      (?:confirm(?:ation)?(?>[[:blank:]]+))?(?:card|button)
    )\b
    (?:
      (?>[[:blank:]]+)to(?>[[:blank:]]+)(?:apply|approve|confirm|finalize)
        (?:(?>[[:blank:]]+)(?:it|that|this))?
      |
      (?>[[:blank:]]+)(?:when|whenever)(?>[[:blank:]]+)
        (?:you(?:['’]re|(?>[[:blank:]]+)are)(?>[[:blank:]]+))?(?:ready|happy|sure)
        (?:#{STAGED_CLAIM_SUBJECTLESS_LIVE_TAIL})?
      |
      #{STAGED_CLAIM_SUBJECTLESS_LIVE_TAIL}
      |
      ,(?>[[:blank:]]*)(?:then(?>[[:blank:]]+))?tell(?>[[:blank:]]+)me
        (?>[[:blank:]]+)if(?>[[:blank:]]+)you(?>[[:blank:]]+)want
        (?>[[:blank:]]+)to(?>[[:blank:]]+)move(?>[[:blank:]]+)on
        (?:
          (?>[[:blank:]]+)to(?>[[:blank:]]+)creating(?>[[:blank:]]+)
          (?:(?>[-[:alnum:]&+'’]+)(?>[[:blank:]]+)){1,5}
          at(?>[[:blank:]]+)\$[[:digit:]][[:digit:],]*(?:\.[[:digit:]]{1,2})?
        )?
    )?
    (?>[[:blank:]]*)[.!]?(?>[[:blank:]]*)\z
  /ix
  STAGED_CLAIM_REPLACEMENT_CARD_STATUS = /
    (?:the|a)(?>[[:blank:]]+)confirm(?:ation)?(?>[[:blank:]]+)(?:card|button)
    (?>[[:blank:]]+)(?:should(?>[[:blank:]]+)be|will(?>[[:blank:]]+)be|is)
    (?>[[:blank:]]+)(?:back|below|here)(?>[[:blank:]]*)[—–-](?>[[:blank:]]*)
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
    # "Staged.", "Staged successfully — confirm below", and the terse production opener.
    /
      #{STAGED_CLAIM_BOUNDARY}
      (?:(?:all|successfully)\s+)?staged(?:\s+(?:now|successfully))?\b
      (?!#{STAGED_CLAIM_NEGATED_OBJECT})
      (?!#{STAGED_CLAIM_HISTORICAL_TAIL})
      (?!#{STAGED_CLAIM_COMPLETED_TAIL})
      (?![^.!?\n]*\?)
      (?=\s*(?:\z|[.!]|[—–-]|\band\b|,\s*but\b|
        :\s*(?:please\s+)?(?:confirm|approve)\b|
        ,\s*(?:please\s+)?(?:confirm|approve)\b))
    /ix,
    # Production emits a subjectless participle when it skips api_write. Only the measured frame
    # and two bounded sibling shapes qualify, and the action must end its clause before an exact
    # card instruction. Feature prose such as "Staged deletion of the draft is permanent" cannot
    # enter this arm.
    /
      \Astaged(?>[[:blank:]]+)#{STAGED_CLAIM_SUBJECTLESS_ACTION}
      (?>[[:blank:]]*)[.!:](?>[[:space:]]*)
      #{STAGED_CLAIM_SUBJECTLESS_CARD_INSTRUCTION}
    /ix,
    # A bare re-staging claim is unambiguous at the start of the reply. Any continuation must be
    # either the measured replacement-card status or an exact card instruction; references to an
    # earlier card and already-applied changes therefore remain untouched.
    /
      \Astaged(?>[[:blank:]]+)again(?>[[:blank:]]*)[.!:]?
      (?>[[:space:]]*)
      (?:
        \z
        |
        (?:#{STAGED_CLAIM_REPLACEMENT_CARD_STATUS})?
        #{STAGED_CLAIM_SUBJECTLESS_CARD_INSTRUCTION}
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

  COMPLETE_TURN_TOOL = "complete_turn"
  TURN_OUTCOME_REPLY_ONLY = "reply_only"
  TURN_OUTCOME_PROPOSAL_READY = "proposal_ready"
  TURN_OUTCOMES = [TURN_OUTCOME_REPLY_ONLY, TURN_OUTCOME_PROPOSAL_READY].freeze
  # The card owns every action-specific detail. Keeping the confirmation sentence server-owned
  # means a creator only sees it after this process has a real proposal to persist with the turn.
  PROPOSAL_READY_REPLY = "I prepared that change. Review it below, then confirm it when you're ready."
  TURN_CONTRACT_FAILURE_REPLY = "I couldn't finish that response. Please try again."
  # One correction is enough to repair a missing or contradictory terminal outcome without turning
  # every response into an open-ended retry loop.
  MAX_TURN_CONTRACT_RETRIES = 1
  # A correction may need one turn to call api_write and one more to return the typed final outcome.
  # Reserve both even when the invalid final turn arrives at the normal iteration cap.
  TURN_CONTRACT_RECOVERY_ITERATIONS = 2
  TURN_CONTRACT_CORRECTION = <<~TEXT.strip
    Your last response did not finish with a valid complete_turn call. Repeat the response, write the
    creator-facing text before the tool call, then call complete_turn exactly once and as the only
    tool in that response. Use outcome reply_only when this turn has no proposed change. Use outcome
    proposal_ready only after api_write returned proposed: true in this same turn.
  TEXT
  PROPOSAL_OUTCOME_CORRECTION = <<~TEXT.strip
    This turn already has a proposed change from api_write, but your final outcome did not report it.
    Do not call api_write again. Finish with complete_turn as the only tool and use outcome
    proposal_ready.
  TEXT
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

    You have three tools:
    - api_read: run any READ endpoint to fetch live data (products, sales, payouts, discounts,
      subscribers, upsells, emails, tax forms, earnings, profile, and more). These run immediately.
    - api_write: prepare any change (create/update/delete products, discounts, variants, upsells,
      emails, refunds, shipping, licenses, profile, and more; existing Store Agent webhooks can be
      listed and deleted, but the Store Agent cannot create webhooks). Writes never take effect
      immediately — they produce a proposed change the creator reviews and confirms in the UI.
    - complete_turn: finish every creator-facing reply with a typed outcome after all api_read or
      api_write results are back.

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
    - Never claim a change has already been made. On a turn where you called api_write, your final
      text is replaced with fixed server copy telling the creator the change is ready to confirm, so
      answer any informational part of their request BEFORE calling api_write — in the text you write
      before the call, or in an earlier turn — and keep the final text after api_write minimal.
    - You cannot see the creator's dashboard. Never invent or describe dashboard screens, settings
      pages, pickers, or menus, and never send the creator to a screen you are not certain exists.
      If a task needs something you have no endpoint for, say so plainly instead of guessing at UI
      directions.
    - The dashboard product editor lets creators add up to 10 tags per product, and each tag must be
      2-20 characters. Existing products can have more tags from older/API paths, so describe this
      as the editor's limit, not a universal data limit, and never state a different editor limit.
    - You cannot create webhooks. Settings > Advanced > Ping fires on SALES ONLY, so offer it for
      sale webhooks and nothing else — never for cancellation, refund, dispute, or subscription
      events. Those are still self-serve on that same page: the creator creates their own app under
      Settings > Advanced > Applications, generates an access token, and subscribes through the
      Gumroad API, which accepts every event type. The help center has no webhook article — point
      them at "Create an application for the API" for the app and token steps, and at the API
      documentation at gumroad.com/api for the subscribe call itself. Existing Store Agent webhooks
      can still be listed and deleted.
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
    - The creator's storefront has THREE separate content surfaces, and you must not confuse them or
      deny the ones you have fewer tools for:
        1. The profile page itself. Either the creator's own tabs and sections (Gumroad's normal
           profile — read it with get_user_profile_layout) or a custom HTML takeover
           (get_user_custom_html), never both at once. get_user_custom_html coming back empty means
           only "no custom HTML" — it does NOT mean the storefront is Gumroad's untouched default.
           Headings the creator sees on their storefront are their own section headers, so read
           get_user_profile_layout before you say anything about a heading, and never claim the
           default profile ships a heading of its own.
        2. Standalone pages under the creator's store url, listed with list_pages. These are real:
           the creator manages them under "Pages" in the dashboard, and Gumroad's CLI drives them
           with `gumroad pages pull/preview/push`. You can list them with list_pages and read one
           with get_page, but you cannot create, update, or delete them. NEVER tell a creator that
           standalone pages don't exist on Gumroad, or that those CLI commands aren't real features.
        3. Each product's own landing page (get_product_custom_html), separate from both of the
           above.
      When a creator describes content you cannot find, first read the surface they named. If the
      surface is unclear, inspect the profile layout and compact standalone-page list before fetching
      a full page body. Do not claim content is missing until you have checked the relevant surfaces.
    - Store colors and fonts come from the creator's store theme: a background color, a highlight
      (accent) color, and a font. Read them with get_user_theme, which also lists the surfaces they
      cover. They apply to the storefront AND to every product page — product pages ARE themed, so
      never tell a creator their product pages can't be styled. You have no endpoint to change the
      theme, but the creator changes it themselves in Settings > Profile > Design, which previews
      the change before saving: when they want different colors or a different font, send them
      there. A
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
      theme, so never author a whole custom page as a way to change a colour.
      Every published page is served with the
      creator's live store data injected into it as a <script id="gumroad-data"
      type="application/json"> element, refreshed on every page load. That JSON holds exactly
      five keys and NOTHING else: products (name, url, price, native_type, thumbnail_url,
      cover_url, description), posts (name, url, published_at), pages (name), and the counts
      products_total and posts_total. Those are
      the ONLY field names that exist — reading any other name (say a field you'd expect but
      that isn't in this list) gives undefined and renders blank or broken, so never invent
      one. The JSON is injected on the PROFILE page only, never on a page you author at its
      own slug — a page reading it there sees nothing and its product grid renders empty, so
      build slugged pages from HTML you write rather than from this JSON. The url values are
      built on the creator's own store host (their custom domain when they have a live one,
      their gumroad.com subdomain otherwise) and are safe to use verbatim; the page must not
      rewrite them onto another host, which breaks the link. The products and posts arrays are
      capped at #{Pages::ProfileData::MAX_ITEMS} entries, so on a large
      catalogue products_total exceeds products.length, and on a long archive posts_total
      exceeds posts.length. Whenever either total exceeds the array the page renders, the page
      MUST show a visible count for that section (for example "Showing 100 of 114 products",
      "Showing 100 of 260 posts") — a grid or archive that quietly renders only part of what the
      creator has reads to them as items having vanished. It does NOT contain the
      creator's name, bio, avatar, or any user object — a page that tries to read those from
      the JSON renders them blank. Build the page to READ that JSON and render the product grid
      and links from it, so the storefront stays current as products are added, renamed, or
      removed — never hard-code the product list into the HTML. A product's image is
      thumbnail_url, falling back to cover_url; a product can have neither, so write the card
      to leave the image out entirely in that case rather than emitting an <img> with an empty
      src, which shows a broken-image icon. If the products array is empty,
      render a visible empty state (like "No products yet") so the page still reads as a real
      storefront and not a broken or unfinished page.
    - Whenever a page displays a price, render it from the gumroad-prices JSON — a separate
      <script id="gumroad-prices" type="application/json"> element, rebuilt on every request,
      keyed by the last path segment of each product's url. The price in the gumroad-data JSON
      is the creator's raw set price: always their own currency, never discounted, and for
      memberships it can quote a recurrence no buyer selects — so treat it as a fallback string
      only. Each gumroad-prices entry holds price (a formatted string, in the visitor's own
      currency when Gumroad can localize this checkout), price_cents, currency_code, localized
      (true when converted for this visitor), and — only while the creator's default offer code
      discounts the product — original_price and original_price_cents, for rendering the
      struck-through pre-sale price next to the live one. Equivalently, mark up one element per
      price with both data-gumroad-product set to that permalink and data-gumroad-field="price"
      (or "original-price", or "currency"), and the server fills it in server-side — use that
      form when the price is static markup rather than built by a script, since it then renders
      without JavaScript. Whichever you use, write the creator's own price as the element's text
      so the page still reads correctly if a permalink stops matching (except original-price,
      which must stay empty — it renders only during a sale). The prices are served only to
      pages that reference them, so reference the blob by its literal id ("gumroad-prices"),
      never a computed string. The priced set is the same capped product list gumroad-data
      carries, so never write price markup for a product outside it. Both mechanisms exist
      only on the profile page — a slugged page gets neither, so never put price markup there.
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
      data-gumroad-field="name", "price", "description", "rating", or "review-count" with the
      product's live values on every render. That price is the amount a first-time buyer pays —
      default offer code applied, and memberships quoted at their default recurrence — matching
      the native page it replaces. "rating" and "review-count" write nothing when the seller has
      reviews hidden or the product has none, so whatever the page already has inside those
      elements stays — put a sensible fallback there rather than a placeholder.
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
    - End EVERY final reply by calling complete_turn exactly once, as the only tool in that response.
      Write the creator-facing text before the call; on a proposal turn that text is replaced with
      fixed server copy and never shown, so keep it minimal there. Use reply_only when this turn has
      no proposed change. Use proposal_ready only after api_write returned proposed: true in this
      same turn. Never mix complete_turn with api_read or api_write.

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
    @completed_read_targets = {}
    @reads_completed_in_tool_batch = nil
    turn_contract_retries = 0
    @turn_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    remaining_iterations = MAX_TOOL_ITERATIONS
    while remaining_iterations.positive?
      remaining_iterations -= 1
      result = client.messages(
        system: system_prompt,
        messages: conversation,
        tools: tool_schemas,
        max_tokens: MAX_REPLY_TOKENS,
      )
      @last_stop_reason = result.stop_reason
      @turn_iterations_used = MAX_TOOL_ITERATIONS - remaining_iterations
      @turn_contract_retries = turn_contract_retries

      # The model hit MAX_REPLY_TOKENS mid-turn. Whatever came back is incomplete — a cut-off tool
      # call has unusable arguments, and a cut-off text answer would read as a complete reply when
      # it isn't — so stop here with an honest message instead of acting on a truncated turn.
      if result.stop_reason == "max_tokens"
        reply = proposed_action ? PROPOSAL_READY_REPLY : TRUNCATED_REPLY
        return turn_result(reply:, proposed_action:)
      end

      decision = final_turn_decision(result:, proposed_action:)
      case decision.fetch(:status)
      when :complete
        return turn_result(reply: decision.fetch(:reply), proposed_action:)
      when :invalid
        retrying = turn_contract_retries < MAX_TURN_CONTRACT_RETRIES
        log_turn_contract_mismatch(reason: decision.fetch(:reason), retrying:)
        unless retrying
          return turn_result(reply: fallback_reply_for(decision:, proposed_action:), proposed_action:)
        end

        turn_contract_retries += 1
        remaining_iterations = [remaining_iterations, TURN_CONTRACT_RECOVERY_ITERATIONS].max
        append_turn_contract_correction(conversation, result:, decision:, proposed_action:)
        next
      end

      proposed_action = apply_tool_uses(text: result.text, tool_uses: result.tool_uses, conversation:, proposed_action:)
    end

    @turn_contract_retries = turn_contract_retries
    turn_result(reply: tool_cap_reply(proposed_action), proposed_action:)
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
  # `on_reply_complete` (optional) is invoked with { outcome:, reply:, proposed_action:, objects: } the
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
    @completed_read_targets = {}
    @reads_completed_in_tool_batch = nil
    turn_contract_retries = 0
    @turn_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    remaining_iterations = MAX_TOOL_ITERATIONS
    while remaining_iterations.positive?
      remaining_iterations -= 1
      # Stream this turn's text deltas live. We don't yet know if the turn is final (text-only) or an
      # intermediate tool-use turn that happens to include preamble text, so track whether anything
      # was streamed: if the turn turns out to be a tool-use turn, we emit :reset to discard its
      # preamble from the UI, and only the final (tool_uses-blank) turn's text survives on screen.
      emitted_any = false
      # Once api_write produced a proposal, the model no longer owns the confirmation sentence.
      # Buffer any final prose and emit the fixed server copy only after the proposal is persisted.
      suppress_model_text = proposed_action.present?
      result =
        begin
          client.stream_messages(
            system: system_prompt,
            messages: conversation,
            tools: tool_schemas,
            max_tokens: MAX_REPLY_TOKENS,
            # A corrupted tool call is recovered by replaying the turn without streaming, which
            # regenerates the reply from the start. Tool-use turns usually stream a sentence of
            # preamble first, so without a way to clear it that recovery could never run — the
            # client refuses to replay over text the seller can still see. This is the same :reset
            # the normal tool-use path below uses to discard preamble, so the seller ends up in the
            # identical state: an empty transcript that the recovered turn then fills in.
            on_discard_streamed_text: -> {
              emit.call(:reset, {}) if emitted_any
              emitted_any = false
            },
          ) do |text|
            unless suppress_model_text
              emitted_any = true
              emit.call(:token, { text: })
            end
          end
        rescue
          # The terminal outcome never arrived, so text already on the client was not validated or
          # persisted. Clear it before the controller reports the error; the web client otherwise
          # keeps the partial answer visible beside that error.
          emit.call(:reset, {}) if emitted_any
          raise
        end
      @last_stop_reason = result.stop_reason
      @turn_iterations_used = MAX_TOOL_ITERATIONS - remaining_iterations
      @turn_contract_retries = turn_contract_retries

      # Same truncation handling as #respond. Anything this turn streamed is incomplete, so tell
      # the UI to discard it and stream the honest fallback instead of leaving half an answer (or
      # half a tool call's preamble) on screen as if it were the finished reply.
      if result.stop_reason == "max_tokens"
        reply = proposed_action ? PROPOSAL_READY_REPLY : TRUNCATED_REPLY
        return finish_stream(reply:, proposed_action:, last_user_message:, emit:, on_reply_complete:) do |turn|
          emit.call(:reset, {}) if emitted_any
          emit.call(:token, { text: turn[:reply] })
        end
      end

      decision = final_turn_decision(result:, proposed_action:)
      case decision.fetch(:status)
      when :complete
        reply = decision.fetch(:reply)
        return finish_stream(reply:, proposed_action:, last_user_message:, emit:, on_reply_complete:) do |turn|
          # Normal reply text was already streamed. Proposal copy was deliberately withheld, and a
          # buffered client may also return final text without yielding a delta.
          emit.call(:token, { text: turn[:reply] }) if suppress_model_text || !emitted_any
        end
      when :invalid
        retrying = turn_contract_retries < MAX_TURN_CONTRACT_RETRIES
        log_turn_contract_mismatch(reason: decision.fetch(:reason), retrying:)
        unless retrying
          reply = fallback_reply_for(decision:, proposed_action:)
          return finish_stream(reply:, proposed_action:, last_user_message:, emit:, on_reply_complete:) do |turn|
            emit.call(:reset, {}) if emitted_any
            emit.call(:token, { text: turn[:reply] })
          end
        end

        emit.call(:reset, {}) if emitted_any
        turn_contract_retries += 1
        remaining_iterations = [remaining_iterations, TURN_CONTRACT_RECOVERY_ITERATIONS].max
        append_turn_contract_correction(conversation, result:, decision:, proposed_action:)
        next
      end

      # Intermediate tool-use turn: any text it streamed was preamble, not the answer. Tell the UI to
      # clear it so the seller never sees an interim claim that gets replaced by the real reply.
      emit.call(:reset, {}) if emitted_any
      proposed_action = apply_tool_uses(text: result.text, tool_uses: result.tool_uses, conversation:, proposed_action:)
    end

    # Hit the tool-iteration cap. Persist the server-owned fallback before its first socket write.
    reply = tool_cap_reply(proposed_action)
    finish_stream(reply:, proposed_action:, last_user_message:, emit:, on_reply_complete:) do |turn|
      emit.call(:token, { text: turn[:reply] })
    end
  end

  private
    attr_reader :seller, :pundit_user

    def turn_result(reply:, proposed_action:)
      outcome = proposed_action ? TURN_OUTCOME_PROPOSAL_READY : TURN_OUTCOME_REPLY_ONLY
      log_turn_metrics(outcome:)
      {
        outcome:,
        reply:,
        proposed_action: proposed_action&.as_json,
        objects: deduped_objects,
      }
    end

    # One structured line per completed turn (gumroad-private#1879's canary needs this to compare
    # Grok against the Opus baseline: model, tool iterations, stop_reason, contract retries, and
    # latency are exactly the pass-bar signals the ramp checks each step against).
    def log_turn_metrics(outcome:)
      latency_ms = @turn_started_at ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @turn_started_at) * 1000).round : nil
      Rails.logger.info(
        {
          event: "store_agent_turn",
          model: @_client_model,
          outcome:,
          stop_reason: @last_stop_reason,
          tool_iterations: @turn_iterations_used,
          contract_retries: @turn_contract_retries,
          latency_ms:,
        }.to_json,
      )
    end

    # A final model turn is valid only when its typed outcome agrees with the proposal this service
    # actually built. API calls remain ordinary intermediate turns. We reject a terminal marker
    # mixed with any other tool before dispatching those tools, because otherwise the marker could
    # certify a state that changed while we processed the same response.
    def final_turn_decision(result:, proposed_action:)
      tool_uses = Array(result.tool_uses)
      complete_turn_calls = tool_uses.select { |tool_use| tool_use[:name] == COMPLETE_TURN_TOOL }

      if complete_turn_calls.empty?
        return { status: :tools } if tool_uses.any?

        reply = result.text.to_s.strip
        reason = phantom_staged_claim?(reply:, proposed_action:) ? :staging_claim_without_proposal : :missing_complete_turn
        return { status: :invalid, reason: }
      end

      return { status: :invalid, reason: :mixed_or_duplicate_complete_turn } unless tool_uses.one? && complete_turn_calls.one?
      return { status: :invalid, reason: :invalid_complete_turn_stop_reason } unless result.stop_reason == "tool_use"

      outcome = sanitize_param_hash(complete_turn_calls.first[:input])["outcome"]
      return { status: :invalid, reason: :invalid_complete_turn_outcome } unless TURN_OUTCOMES.include?(outcome)

      if proposed_action.present?
        return { status: :invalid, reason: :proposal_not_reported } unless outcome == TURN_OUTCOME_PROPOSAL_READY

        return { status: :complete, reply: PROPOSAL_READY_REPLY }
      end

      return { status: :invalid, reason: :proposal_ready_without_proposal } unless outcome == TURN_OUTCOME_REPLY_ONLY

      reply = result.text.to_s.strip
      return { status: :invalid, reason: :blank_reply } if reply.blank?
      return { status: :invalid, reason: :staging_claim_without_proposal } if reply == PROPOSAL_READY_REPLY
      return { status: :invalid, reason: :staging_claim_without_proposal } if phantom_staged_claim?(reply:, proposed_action:)

      { status: :complete, reply: }
    end

    def fallback_reply_for(decision:, proposed_action:)
      return PROPOSAL_READY_REPLY if proposed_action.present?
      return NOTHING_STAGED_REPLY if [:staging_claim_without_proposal, :proposal_ready_without_proposal].include?(decision.fetch(:reason))

      TURN_CONTRACT_FAILURE_REPLY
    end

    def turn_contract_correction(decision:, proposed_action:)
      return PROPOSAL_OUTCOME_CORRECTION if proposed_action.present?
      return STAGED_CLAIM_CORRECTION if [:staging_claim_without_proposal, :proposal_ready_without_proposal].include?(decision.fetch(:reason))

      TURN_CONTRACT_CORRECTION
    end

    # When the rejected response contains tool calls, replay every call and answer every id with an
    # error. Anthropic requires each assistant tool_use to be followed immediately by matching
    # tool_result blocks; sending a plain correction after it would make the next request invalid.
    # No rejected tool runs, including an api_write mixed with complete_turn.
    def append_turn_contract_correction(conversation, result:, decision:, proposed_action: nil)
      correction = turn_contract_correction(decision:, proposed_action:)
      tool_uses = Array(result.tool_uses)

      if tool_uses.any?
        assistant_content = []
        assistant_content << { type: "text", text: result.text.to_s } if result.text.to_s.strip.present?
        assistant_content.concat(
          tool_uses.map do |tool_use|
            {
              type: "tool_use",
              id: tool_use[:id],
              name: tool_use[:name],
              input: tool_use[:input].is_a?(Hash) ? tool_use[:input] : {},
            }
          end,
        )
        conversation << { role: "assistant", content: assistant_content }
        conversation << {
          role: "user",
          content: tool_uses.map do |tool_use|
            { type: "tool_result", tool_use_id: tool_use[:id], content: { error: correction }.to_json }
          end,
        }
      else
        conversation << { role: "assistant", content: result.text.to_s } if result.text.to_s.strip.present?
        conversation << { role: "user", content: correction }
      end
    end

    def log_turn_contract_mismatch(reason:, retrying:)
      if reason == :staging_claim_without_proposal
        log_phantom_staged_claim(retrying:)
        return
      end

      outcome = retrying ? "retrying" : "gave up"
      message = "Store agent final turn did not match proposal state (#{reason}, #{outcome})"
      # The retry recovers this almost every time, and reporting the recoverable half buried the
      # signals worth seeing. Only the give-up is a failure; every other reason stays error-level.
      if reason == :missing_complete_turn && retrying
        Rails.logger.info(message)
        return
      end

      Rails.logger.warn(message)
      ErrorNotifier.notify(
        "Store agent final turn did not match proposal state",
        reason: reason.to_s,
        outcome:,
      )
    end

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

      # A read only satisfies a write precondition after its result has gone back to the model.
      # Otherwise the model could request a read and a speculative write in the same tool-use batch,
      # before it had seen the page it was supposed to preserve.
      @reads_completed_in_tool_batch = {}
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
      @completed_read_targets.merge!(@reads_completed_in_tool_batch)
      @reads_completed_in_tool_batch = nil
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

      # A reply can quote an earlier assistant message before giving its current answer. Remove only
      # that attributed clause; a later current claim in the same reply still goes through the guard.
      candidate = reply.gsub(
        /\b(?:the\s+)?(?:earlier|previous)\s+(?:reply|message)\s+
          (?:said|claimed|read)\s*:\s*[^.!?;\n]*
          (?:[.!?;]+|\n+|\z)[[:space:]]*/ix,
      ) do
        # A leading quote can disappear entirely so a current subjectless claim becomes the new
        # start. A quote after introductory prose still needs a sentence boundary so the existing
        # subjectful patterns can recognize the current assertion that follows it.
        Regexp.last_match.pre_match.blank? ? "" : ". "
      end
      STAGED_CLAIM_PATTERNS.any? { |pattern| candidate.match?(pattern) }
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
        PROPOSAL_READY_REPLY
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
      result = turn_result(reply:, proposed_action:)
      on_reply_complete&.call(result)
      before_trailing_events&.call(result)
      emit.call(:objects, { objects: }) if objects.any?
      emit.call(:proposed_action, { proposed_action: proposed_action.as_json }) if proposed_action
      suggestions = follow_up_suggestions(reply: result[:reply], last_user_message:)
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
      window = Array(messages).last(MAX_HISTORY_MESSAGES)
      current_message_index = window.rindex { |msg| (msg[:role] || msg["role"]) == "user" && (msg[:content] || msg["content"]).to_s.strip.present? }

      history = window.each_with_index.filter_map do |msg, index|
        role = msg[:role] || msg["role"]
        content = (msg[:content] || msg["content"]).to_s.strip
        next if content.blank?
        next unless %w[user assistant].include?(role)

        proposal_state = msg[:proposal_state] || msg["proposal_state"]
        state_suffix =
          if role == "assistant" && proposal_state.present?
            "\n\n[Server proposal state: #{proposal_state}]"
          else
            ""
          end
        limit = index == current_message_index ? MAX_CURRENT_MESSAGE_LENGTH : MAX_MESSAGE_LENGTH
        content = content.truncate(limit - state_suffix.length, omission: "...")
        { role:, content: "#{content}#{state_suffix}" }
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

    # Two generic API tools drive the whole catalog. `complete_turn` is a terminal marker: unlike
    # the API tools it never runs an operation, and the service validates it before accepting the
    # model's text as the final seller-facing reply.
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
      params = sanitize_param_hash(arguments["params"])
      if (error = endpoint.unknown_param_keys_error(params))
        return [{ error: }, nil]
      end

      # Catalog-owned values win over model input, so a specialized read can share a controller
      # route without exposing its fixed query contract to the model or adding endpoint-id branches.
      params.merge!(endpoint.forced_params)
      result = api_client.get(path, params)
      record_successful_read(endpoint:, expanded_path: path, result:)
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

      if endpoint.requires_read.present?
        required_read = Ai::StoreAgentApiCatalog.find(endpoint.requires_read)
        unless required_read&.read?
          raise Error, "Catalog endpoint #{endpoint.id} requires invalid read endpoint #{endpoint.requires_read}"
        end

        required_path = required_read.expand_path(path_params)
        required_target = [required_read.id, required_path]
        unless @completed_read_targets&.key?(required_target)
          log_missing_required_read(endpoint:, required_read:)
          return [
            {
              error: "#{endpoint.id} requires a successful full read of this exact target first. Only if the seller explicitly requested this custom-page work, call #{required_read.id} with api_read, wait for its result, then retry #{endpoint.id} in this turn. Otherwise, do not read the page body and do not retry the write. Status or metadata-only reads do not count.",
              corrective_action: {
                condition: "The seller explicitly requested this custom-page work.",
                if_requested: {
                  tool: "api_read",
                  endpoint: required_read.id,
                  path_params: path_params.slice(*required_read.path_params),
                  after_success: {
                    action: "retry_write",
                    endpoint: endpoint.id,
                    timing: "this_turn",
                  },
                },
                otherwise: {
                  action: "do_not_read_or_retry",
                  instruction: "Do not read the page body and do not retry the write.",
                },
              },
            },
            nil,
          ]
        end
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
      normalize_product_currency_param!(endpoint, body)

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

    # A read precondition is satisfied only by a successful response from the exact catalog endpoint
    # and expanded target path the write names. A status endpoint may share the same HTTP route, but
    # its distinct catalog id cannot unlock a body-changing write.
    def record_successful_read(endpoint:, expanded_path:, result:)
      return unless successful_api_read?(result)

      (@reads_completed_in_tool_batch || @completed_read_targets)[[endpoint.id, expanded_path]] = true
    end

    def successful_api_read?(result)
      return false unless result.is_a?(Hash)
      return false if result["success"] == false || result[:success] == false

      status = result["http_status"] || result[:http_status]
      status.blank? || status.to_i.between?(200, 299)
    end

    # Keep the message fixed in both logs and Sentry so every blocked proposal groups together.
    # Endpoint ids and the catalog path template are safe structured context. Never report the
    # expanded path because its model-supplied target id could contain seller text. The notifier
    # also strips ambient request data from this event.
    def log_missing_required_read(endpoint:, required_read:)
      Rails.logger.warn(MISSING_REQUIRED_READ_MESSAGE)
      ErrorNotifier.notify(
        MISSING_REQUIRED_READ_MESSAGE,
        exclude_request_context: true,
        write_endpoint: endpoint.id,
        required_read_endpoint: required_read.id,
        required_read_path: required_read.path,
      )
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

    def normalize_product_currency_param!(endpoint, body)
      return unless endpoint.id.in?(%w[create_product update_product]) && body.key?("price_currency_type")

      body["price_currency_type"] = body["price_currency_type"].to_s.strip.downcase
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
      @_client ||= if Ai::AnthropicClient.openrouter_configured? && Feature.active?(GROK_RAMP_FEATURE, seller)
        @_client_model = OPENROUTER_MODEL
        Ai::AnthropicClient.new(timeout: REQUEST_TIMEOUT_IN_SECONDS, model: OPENROUTER_MODEL, fallback_model: OPENROUTER_FALLBACK_MODEL)
      else
        @_client_model = MODEL
        Ai::AnthropicClient.new(timeout: REQUEST_TIMEOUT_IN_SECONDS, model: MODEL)
      end
    end

    # Two generic API tools plus one terminal marker. The endpoint id (constrained to the catalog by
    # an enum) selects which of the ~60 real API endpoints to hit; path_params/params carry the ids
    # and payload. Anthropic tool schemas use `input_schema` instead of OpenAI's
    # `function.parameters`.
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
        tool_schema(
          COMPLETE_TURN_TOOL,
          "Finish the creator-facing reply after every API tool result is back. Call exactly once and as the only tool in the final response. Write the reply text before this call; on a proposal turn that text is replaced with fixed server copy and never shown. Use proposal_ready only when api_write returned proposed: true in this same turn; otherwise use reply_only.",
          {
            outcome: {
              type: "string",
              enum: TURN_OUTCOMES,
              description: "Whether this turn has a real proposed change waiting for confirmation.",
            },
          },
          required: ["outcome"],
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
