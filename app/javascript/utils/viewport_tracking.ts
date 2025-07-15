export const trackElementInViewport = (
  element: HTMLElement,
  callback: () => void,
  options: { threshold?: number; once?: boolean } = {}
) => {
  const { threshold = 0.5, once = true } = options;
  
  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          callback();
          if (once) {
            observer.unobserve(element);
          }
        }
      });
    },
    { threshold }
  );
  
  observer.observe(element);
  return observer;
};