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
    coin.currentMouseX = 0;
    coin.currentMouseY = 0;
    coin.targetMouseX = 0;
    coin.targetMouseY = 0;
  });

  let animationFrameId = null;

  function lerp(start, end, factor) {
    return start + (end - start) * factor;
  }

  function animate() {
    coins.forEach((coin) => {
      coin.currentMouseX = lerp(coin.currentMouseX, coin.targetMouseX, 0.1);
      coin.currentMouseY = lerp(coin.currentMouseY, coin.targetMouseY, 0.1);

      const combinedY = coin.currentMouseY + coin.scrollOffsetY;
      coin.style.transform = `translate3d(${coin.currentMouseX}px, ${combinedY}px, 0)`;
    });

    animationFrameId = requestAnimationFrame(animate);
  }

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
      coin.targetMouseX = deltaX * intensity;
      coin.targetMouseY = deltaY * intensity;
    });
  };

  const throttledMouseMove = throttle(handleMouseMove, 16);

  const handleScroll = () => {
    const scrollY = window.scrollY;
    coins.forEach((coin) => {
      const scrollIntensity = parseFloat(coin.dataset.scrollIntensity) || -0.05;
      coin.scrollOffsetY = scrollY * scrollIntensity;
    });
  };

  const isTouchDeviceOrSmallScreen = window.matchMedia("(pointer: coarse)").matches || window.innerWidth < 1024;

  if (!isTouchDeviceOrSmallScreen) {
    container.addEventListener("mousemove", throttledMouseMove);
  }

  animationFrameId = requestAnimationFrame(animate);

  const throttledScroll = throttle(handleScroll, 16);

  window.addEventListener("scroll", throttledScroll);

  handleScroll();

  return () => {
    if (animationFrameId) {
      cancelAnimationFrame(animationFrameId);
    }
  };
}

if (document.readyState === "loading") {
  window.addEventListener("DOMContentLoaded", initHeroCoinParallax);
} else {
  initHeroCoinParallax();
}
