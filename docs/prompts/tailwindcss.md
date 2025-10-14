# Tailwind CSS Migration Prompt

Use this prompt when asking AI assistants to help migrate CSS components to Tailwind:

---

## Prompt

I'm migrating a CSS component to Tailwind CSS. Please help me convert the existing styles following these strict guidelines:

### ❌ Not Allowed

1. **No `@apply` directives** - All Tailwind classes must be applied directly in the markup, not through CSS files
2. **No new utility classes** - Only use Tailwind's built-in utilities; don't create custom ones
3. **No arbitrary values without justification** - Avoid `[#hex]`, `[10px]`, etc. Use design system tokens. If you must use arbitrary values, explain why they're necessary
4. **No inline styles** - All styling must be done through Tailwind classes

### ✅ Required Practices

#### Mobile-First Responsive Design

- Design mobile-first and use `sm:`, `md:`, `lg:` prefixes only where values actually change
- Don't prefix every utility with a breakpoint if the value is the same
  - ❌ Bad: `hidden lg:flex lg:mx-2 lg:items-center lg:justify-between`
  - ✅ Good: `hidden lg:flex mx-2 items-center justify-between`

#### Conditional Classes

- Prefer using our `classNames` utility over `cx`, `twMerge`, or ternary operators

  ```tsx
  // Good
  import { classNames } from "$app/utils/classNames";
  classNames(
    "base-class",
    condition && "conditional-class",
  ) // Avoid
  `base-class ${condition ? "conditional-class" : ""}`;

  import cx from "classnames";
  cx("base-class", condition && "conditional-class");

  import twMerge from "tailwind-merge";
  twMerge("base-class", condition && "conditional-class");
  ```

#### Avoid `!important`

- Avoid bang modifiers (`mt-2!`, `flex!`, etc.)
- Instead, investigate the root cause of the specificity conflict and fix it properly
- Refactor the cascade or component structure if needed

#### Typography

- Consider using the `prose` plugin for content-heavy areas with paragraphs, lists, and rich text

### Output Requirements

When providing the migrated code:

1. Show the complete component with all Tailwind classes applied
2. Explain any arbitrary values you had to use (with justification)
3. Point out any specificity issues you encountered and how you resolved them
4. Note any areas where the `prose` plugin might be beneficial

---

## Usage

Copy the prompt above and paste it into your AI assistant when working on Tailwind migrations. Include the component code you're migrating after the prompt.
