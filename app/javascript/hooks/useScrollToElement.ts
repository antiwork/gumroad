import React from "react";

/**
 * Custom hook to scroll to an element after it has been fully rendered and painted by the browser.
 *
 * This hook uses a double requestAnimationFrame pattern to ensure the target element
 * is completely rendered before scrolling to it. This is more reliable than using
 * arbitrary timeouts because it syncs with the browser's actual render cycle.
 *
 * ## How it works:
 * 1. First RAF: Runs before the browser's first repaint (after React DOM updates)
 * 2. Browser paints the first frame (element is now visible)
 * 3. Second RAF: Runs before the browser's second repaint (element is stable)
 * 4. Scroll happens smoothly to the now-fully-rendered element
 *
 * ## Timeline:
 * ```
 * React Effect → RAF #1 → Browser Paint → RAF #2 → Scroll → Browser Paint (scroll animation)
 * ```
 *
 * @param shouldScroll - Boolean condition to trigger the scroll
 * @param options - ScrollIntoViewOptions to customize the scroll behavior
 * @returns A ref to attach to the target element
 *
 * @example
 * ```tsx
 * function MyComponent({ showHero }: { showHero: boolean }) {
 *   const resultsRef = useScrollToElement(showHero, {
 *     behavior: "smooth",
 *     block: "start"
 *   });
 *
 *   return (
 *     <div>
 *       {showHero && <Hero />}
 *       <section ref={resultsRef}>
 *         Results go here
 *       </section>
 *     </div>
 *   );
 * }
 * ```
 */
export function useScrollToElement<T extends HTMLElement = HTMLElement>(
  shouldScroll: boolean,
  options: ScrollIntoViewOptions = { behavior: "smooth", block: "start" },
  dependencies: readonly unknown[] = [],
  delay = 200,
): React.RefObject<T> {
  const elementRef = React.useRef<T>(null);

  React.useEffect(() => {
    if (shouldScroll && elementRef.current) {
      // Use double requestAnimationFrame to ensure the page is fully rendered and painted
      // First RAF: scheduled after the current frame's DOM updates
      // Second RAF: scheduled after the browser has painted those updates
      let rafId2: number;

      const rafId1 = requestAnimationFrame(() => {
        rafId2 = requestAnimationFrame(() => {
          setTimeout(() => {
            elementRef.current?.scrollIntoView(options);
          }, delay);
        });
      });

      // Cleanup: cancel any pending animation frames if the component unmounts
      // or if the effect runs again before the scroll completes
      return () => {
        cancelAnimationFrame(rafId1);
        cancelAnimationFrame(rafId2);
      };
    }
  }, [shouldScroll, options.behavior, options.block, options.inline, ...dependencies]);

  return elementRef;
}
