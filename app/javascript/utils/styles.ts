import { escapeRegExp } from "$app/utils";

export function getAppliedStyles(el: HTMLElement) {
  const styles = new Map<string, string>();
  const computed = getComputedStyle(el);
  const setStyle = (modifier: string, rule: CSSStyleRule) => {
    const css = rule.style.cssText
      .replace(/--[\w-]+:[^;]+;\s*/gu, "")
      .replace(/([\w-]+):\s+inherit/gu, (_, str: string) => computed.getPropertyValue(str))
      .replace(/var\((--[\w-]+?)\)/gu, (_, str: string) => computed.getPropertyValue(str));
    styles.set(modifier, (styles.get(modifier) ?? "") + css);
  };
  for (const sheet of document.styleSheets) {
    try {
      for (const rule of sheet.cssRules) {
        if (!(rule instanceof CSSStyleRule)) continue;
        if (el.matches(rule.selectorText)) setStyle("", rule);
        else {
          const modifiers = new Set<string>();
          const regex = /(::?[\w-]+)(?=[^\w\-()])/gu;
          let match: RegExpMatchArray | null;
          while ((match = regex.exec(rule.selectorText)) && match[1]) modifiers.add(match[1]);
          for (const modifier of modifiers) {
            const escaped = escapeRegExp(modifier);
            const withoutModifier = rule.selectorText
              .replace(new RegExp(`([^>\\s,])${escaped}`, "gu"), "$1")
              .replace(new RegExp(escaped, "gu"), "*");
            if (el.matches(withoutModifier)) setStyle(modifier, rule);
          }
        }
      }
    } catch {}
  }
  return styles;
}

export function getCssVariable(name: string) {
  return getComputedStyle(document.documentElement).getPropertyValue(`--${name}`);
}
