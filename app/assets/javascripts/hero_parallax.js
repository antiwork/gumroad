function initHeroCoinParallax() {
  const mediaQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (mediaQuery.matches) {
    return;
  }

  const container = document.querySelector("[data-hero-parallax-container]");
  if (!container) return;

  const coins = Array.from(container.querySelectorAll(".hero-coin"));
  if (coins.length === 0) return;

  coins.forEach((coin) => {
    coin.mouseOffsetX = 0;
    coin.mouseOffsetY = 0;
    coin.scrollOffsetY = 0;
  });

  function throttle(func, limit) {
    let lastFunc;
    let lastRan;
    return function (...args) {
      const context = this;
      if (!lastRan) {
        func.apply(context, args);
        lastRan = Date.now();
      } else {
        clearTimeout(lastFunc);
        const timeSinceLastRan = Date.now() - lastRan;
        const delay = Math.max(0, limit - timeSinceLastRan);

        lastFunc = setTimeout(() => {
          if (Date.now() - lastRan >= limit) {
            func.apply(context, args);
            lastRan = Date.now();
          }
        }, delay);
      }
    };
  }

  function applyCombinedTransform(coin) {
    const combinedY = coin.mouseOffsetY + coin.scrollOffsetY;
    coin.style.transform = `translate3d(${coin.mouseOffsetX}px, ${combinedY}px, 0)`;
  }

  const handleMouseMove = (event) => {
    const rect = container.getBoundingClientRect();
    const centerX = rect.left + rect.width / 2;
    const centerY = rect.top + rect.height / 2;

    const mouseX = event.clientX;
    const mouseY = event.clientY;

    const deltaX = mouseX - centerX;
    const deltaY = mouseY - centerY;

    coins.forEach((coin) => {
      const intensity = parseFloat(coin.dataset.parallaxIntensity) || 0.05;
      coin.mouseOffsetX = deltaX * intensity;
      coin.mouseOffsetY = deltaY * intensity;
      applyCombinedTransform(coin);
    });
  };

  const throttledMouseMove = throttle(handleMouseMove, 16);

  const handleScroll = () => {
    const scrollY = window.scrollY;
    coins.forEach((coin) => {
      const scrollIntensity = parseFloat(coin.dataset.scrollIntensity) || -0.05;
      coin.scrollOffsetY = scrollY * scrollIntensity;
      applyCombinedTransform(coin);
    });
  };

  const isTouchDeviceOrSmallScreen = window.matchMedia("(pointer: coarse)").matches || window.innerWidth < 1024;

  if (!isTouchDeviceOrSmallScreen) {
    container.addEventListener("mousemove", throttledMouseMove);
  }

  const throttledScroll = throttle(handleScroll, 16);

  window.addEventListener("scroll", throttledScroll);

  handleScroll();
}

if (document.readyState === "loading") {
  window.addEventListener("DOMContentLoaded", initHeroCoinParallax);
} else {
  initHeroCoinParallax();
}
