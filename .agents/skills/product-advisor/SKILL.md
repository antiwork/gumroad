---
name: product-advisor
description: Analyze and optimize a Gumroad product page for higher conversions. Scores description quality, cover image, pricing, discoverability, and social proof. Generates actionable improvement suggestions with before/after examples. Triggers on: "improve my product", "optimize product page", "product advisor", "review my listing", "product page score", "increase conversions", "product audit", "optimize listing"
argument-hint: [product URL or ID]
allowed-tools: Bash(curl *), Bash(jq *)
---

# Product Advisor

Analyze a Gumroad product page and generate a scored improvement report with specific, actionable suggestions.

## Setup

Requires `GUMROAD_API_TOKEN` exported in your shell. The seller provides their own token.

## Steps

1. Resolve the product. If `$ARGUMENTS` contains a URL, extract the product ID or permalink. If an ID is given directly, use it.
2. Fetch product data:
   ```bash
   curl -s -H "Authorization: Bearer $GUMROAD_API_TOKEN" \
     "https://api.gumroad.com/v2/products/{id}" | jq '.product'
   ```
3. Score the product across five dimensions (0–10 each):

   | Dimension | What to evaluate |
   |-----------|-----------------|
   | Description quality | Clarity, structure, benefit-first copy, formatting |
   | Cover image | Relevance, visual appeal, text legibility, aspect ratio |
   | Pricing strategy | Value perception, price anchoring, tiering, pay-what-you-want range |
   | Discoverability | SEO title, tags, category fit, permalink clarity |
   | Social proof | Reviews, ratings, purchase count, testimonials |

4. For each dimension scoring below 8, write a specific suggestion with a **before/after** example using actual product data.
5. Output the report to `product-advisor-report.md` in the repo root. Never stage or commit this file.

## Output format

```markdown
# Product Advisor: [product name]

## Overall Score: [total]/50

| Dimension | Score | Status |
|-----------|-------|--------|
| Description quality | X/10 | ✅ or ⚠️ |
| Cover image | X/10 | ✅ or ⚠️ |
| Pricing strategy | X/10 | ✅ or ⚠️ |
| Discoverability | X/10 | ✅ or ⚠️ |
| Social proof | X/10 | ✅ or ⚠️ |

## Suggestions

### [Dimension]: X/10

**Current:** [quote from actual product data]

**Suggested:** [improved version]

**Why:** [reasoning]
```

## Important

- **Use the seller's own API token.** Never hardcode or expose credentials.
- **Score from API response data.** Do not invent product attributes.
- **Suggestions must be copy-paste ready.** The seller applies changes directly.
- **Do not modify repo files.** Write the report to repo root as an unstaged file.

## When to use

Run when creating or updating a product listing, before launching a new product, or when conversions underperform.

$ARGUMENTS
