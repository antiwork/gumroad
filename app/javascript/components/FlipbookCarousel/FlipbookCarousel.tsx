import React, { useCallback, useEffect, useRef, useState } from "react";

type FlipbookStickerPosition = "upper-right" | "lower-left" | "lower-right";

interface FlipbookCarouselSticker {
  src: string;
  alt: string;
  position: FlipbookStickerPosition;
}

export interface FlipbookCarouselSlide {
  title: string;
  subtitle: string;
  backgroundColor: string;
  mainImage: {
    src: string;
    alt: string;
  };
  stickers?: FlipbookCarouselSticker[];
}

interface FlipbookCarouselProps {
  slides: FlipbookCarouselSlide[];
  ariaLabel?: string;
}

const ENABLE_DEBUG_CONTROLS = false;

const DESKTOP_CONFIG = {
  xOffsetRight: 51,
  xOffsetLeft: 51,
  zDepthBack: 120,
  zDepthFront: 30,
  yRotation: 25,
  parallaxFactor: 3,
  visibleCards: 2,
  stackDepth: 60,
  scaleDepth: 0,
  skewFallback: 0,
  use2DOnly: false,
};

const MOBILE_CONFIG = {
  ...DESKTOP_CONFIG,
  xOffsetRight: 48,
  xOffsetLeft: 48,
  zDepthBack: 150,
  zDepthFront: 36,
  yRotation: 32,
  parallaxFactor: 4,
  stackDepth: 56,
  scaleDepth: 0.09,
  skewFallback: 4,
};

type FlipbookTransformConfig = typeof DESKTOP_CONFIG;

interface CardTransform {
  transform: string;
  visibility: boolean;
  zIndex: number;
  innerTransform: string;
}

const STICKER_CLASSES: Record<FlipbookStickerPosition, string> = {
  "upper-right": "-right-5 -top-5 w-20 sm:-right-7 sm:-top-7 sm:w-24",
  "lower-left": "-bottom-5 -left-5 w-24 sm:-bottom-7 sm:-left-7 sm:w-32",
  "lower-right": "-bottom-7 -right-5 w-24 sm:-bottom-8 sm:-right-7 sm:w-32",
};

function easeOutQuad(t: number): number {
  return 1 - (1 - t) * (1 - t);
}

function calculateCardTransform(
  cardIndex: number,
  scrollProgress: number,
  config: FlipbookTransformConfig,
): CardTransform {
  const offset = cardIndex - scrollProgress;
  const absOffset = Math.abs(offset);
  const t = Math.min(absOffset, 1);
  const visibility = absOffset <= config.visibleCards + 1;

  let x: number;
  let z: number;
  let rotation: number;
  let zIndex: number;

  if (absOffset < 0.5) {
    const activeT = absOffset * 2;
    const easedActiveT = easeOutQuad(activeT);
    x = offset >= 0 ? easedActiveT * config.xOffsetRight : -easedActiveT * config.xOffsetLeft;
    z = easedActiveT * config.zDepthFront;
    rotation = offset >= 0 ? -easedActiveT * config.yRotation : easedActiveT * config.yRotation;
    zIndex = 100;
  } else {
    x = offset >= 0 ? config.xOffsetRight : -config.xOffsetLeft;
    const sideT = Math.min(absOffset - 0.5, 0.5) * 2;
    const depthBase = config.zDepthFront + sideT * (config.zDepthBack - config.zDepthFront);
    const stackExtra = Math.max(0, absOffset - 1) * config.stackDepth;
    z = depthBase + stackExtra;
    rotation = offset >= 0 ? -config.yRotation : config.yRotation;
    zIndex = Math.round(50 - absOffset * 5);
  }

  let transform: string;
  if (config.use2DOnly) {
    const scale = 1 - absOffset * 0.15;
    transform = `translateX(${x}%) scale(${Math.max(0.5, scale)})`;
  } else {
    const scale = 1 - Math.min(absOffset, 1) * config.scaleDepth;
    const skew = Math.min(absOffset, 1) * config.skewFallback;
    const skewDirection = offset >= 0 ? -1 : 1;
    transform = `translateX(${x}%) translateZ(${-z}px) rotateY(${rotation}deg) skewY(${skew * skewDirection}deg) scale(${scale})`;
  }

  const parallax = offset >= 0 ? -t * config.parallaxFactor : t * config.parallaxFactor;
  return { transform, visibility, zIndex, innerTransform: `translateX(${parallax}%)` };
}

export default function FlipbookCarousel({ slides, ariaLabel = "Feature carousel" }: FlipbookCarouselProps) {
  const slideCount = slides.length;
  const wrapperRef = useRef<HTMLDivElement>(null);
  const scrollDriverRef = useRef<HTMLDivElement>(null);
  const stackRef = useRef<HTMLDivElement>(null);
  const [debugMode, setDebugMode] = useState(false);
  const [debugDisplayProgress, setDebugDisplayProgress] = useState(0);
  const [manualProgress, setManualProgress] = useState(0);
  const [usesMobileGeometry, setUsesMobileGeometry] = useState(false);
  const transformConfig = usesMobileGeometry ? MOBILE_CONFIG : DESKTOP_CONFIG;
  const isDragging = useRef(false);
  const startX = useRef(0);
  const scrollStart = useRef(0);
  const scrollEndTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastProgress = useRef(-1);
  const scrollProgressRef = useRef(0);
  const isVisibleRef = useRef(true);
  const framesSinceLastChange = useRef(0);
  const cardRefs = useRef<{ card: HTMLElement; inner: HTMLElement | null }[]>([]);
  const captionRefs = useRef<HTMLElement[]>([]);
  const rafId = useRef<number>(0);
  const isRunning = useRef(false);
  const intersectionObserverRef = useRef<IntersectionObserver | null>(null);

  useEffect(() => {
    const mediaQuery = window.matchMedia("(max-width: 640px)");
    const handleMediaChange = () => setUsesMobileGeometry(mediaQuery.matches);

    handleMediaChange();
    mediaQuery.addEventListener("change", handleMediaChange);

    return () => mediaQuery.removeEventListener("change", handleMediaChange);
  }, []);

  const getCurrentProgress = useCallback(() => {
    const scrollContainer = scrollDriverRef.current;
    if (!scrollContainer || slideCount <= 0) return 0;

    const scrollWidth = scrollContainer.scrollWidth - scrollContainer.clientWidth;
    if (scrollWidth <= 0) return 0;

    return (scrollContainer.scrollLeft / scrollWidth) * (slideCount - 1);
  }, [slideCount]);

  const applyTransforms = useCallback(
    (progress: number) => {
      scrollProgressRef.current = progress;
      lastProgress.current = progress;

      const cachedCards = cardRefs.current;
      for (let i = 0; i < cachedCards.length; i++) {
        const cached = cachedCards[i];
        if (!cached) continue;

        const { card, inner } = cached;
        const absOffset = Math.abs(i - progress);
        const transforms = calculateCardTransform(i, progress, transformConfig);

        card.style.setProperty("--tx", transforms.transform);
        card.style.setProperty("--z", transforms.zIndex.toString());
        card.style.setProperty("--shadow-y", `${18 + absOffset * 10}px`);
        card.style.setProperty("--shadow-blur", `${34 + absOffset * 18}px`);
        card.style.setProperty("--shadow-opacity", `${Math.max(0.16, 0.36 - absOffset * 0.07)}`);
        card.style.visibility = absOffset > 2 ? "hidden" : transforms.visibility ? "visible" : "hidden";

        if (inner) inner.style.setProperty("--inner-tx", transforms.innerTransform);

        card.classList.toggle("flipbook-card--inactive", absOffset > 2);
        card.classList.toggle("flipbook-card--active", absOffset < 0.05);
      }

      const captions = captionRefs.current;
      for (let i = 0; i < captions.length; i++) {
        const el = captions[i];
        if (!el) continue;

        const absOffset = Math.abs(i - progress);
        const opacity = Math.max(0, 1 - absOffset * 2);
        el.style.opacity = String(opacity);
        el.setAttribute("aria-hidden", opacity < 0.1 ? "true" : "false");
      }
    },
    [transformConfig],
  );

  const updateTransforms = useCallback(() => {
    const progress = getCurrentProgress();

    if (Math.abs(progress - lastProgress.current) < 0.0005) return false;
    applyTransforms(progress);
    return true;
  }, [applyTransforms, getCurrentProgress]);

  const rafLoop = useCallback(() => {
    if (!isRunning.current || !isVisibleRef.current) return;

    if (updateTransforms()) {
      framesSinceLastChange.current = 0;
      rafId.current = requestAnimationFrame(rafLoop);
      return;
    }

    framesSinceLastChange.current++;
    if (framesSinceLastChange.current < 5) {
      rafId.current = requestAnimationFrame(rafLoop);
    } else {
      isRunning.current = false;
    }
  }, [updateTransforms]);

  const wakeRafLoop = useCallback(() => {
    if (!isRunning.current && isVisibleRef.current) {
      isRunning.current = true;
      framesSinceLastChange.current = 0;
      rafId.current = requestAnimationFrame(rafLoop);
    }

    const wrapper = wrapperRef.current;
    if (scrollEndTimer.current) clearTimeout(scrollEndTimer.current);
    scrollEndTimer.current = setTimeout(() => {
      if (wrapper && isDragging.current) {
        isDragging.current = false;
        wrapper.classList.remove("is-dragging");
      }
    }, 150);
  }, [rafLoop]);

  useEffect(() => {
    const wrapper = wrapperRef.current;
    const stack = stackRef.current;
    if (!wrapper || !stack) return;

    const cards = stack.querySelectorAll(".flipbook-card");
    cardRefs.current = Array.from(cards).flatMap((card) => {
      if (!(card instanceof HTMLElement)) return [];

      const inner = card.querySelector(".flipbook-card__inner");
      return [{ card, inner: inner instanceof HTMLElement ? inner : null }];
    });

    applyTransforms(getCurrentProgress());

    intersectionObserverRef.current = new IntersectionObserver(
      (entries) => {
        const entry = entries[0];
        if (!entry) return;

        isVisibleRef.current = entry.isIntersecting;
        if (entry.isIntersecting && !isRunning.current) {
          isRunning.current = true;
          framesSinceLastChange.current = 0;
          rafId.current = requestAnimationFrame(rafLoop);
        } else if (!entry.isIntersecting && isRunning.current) {
          isRunning.current = false;
          cancelAnimationFrame(rafId.current);
        }
      },
      { threshold: 0.1 },
    );

    intersectionObserverRef.current.observe(wrapper);

    return () => {
      intersectionObserverRef.current?.disconnect();
      isRunning.current = false;
      cancelAnimationFrame(rafId.current);
      if (scrollEndTimer.current) clearTimeout(scrollEndTimer.current);
    };
  }, [applyTransforms, getCurrentProgress, rafLoop]);

  useEffect(() => {
    if (!ENABLE_DEBUG_CONTROLS) return;

    const handleGlobalKeyDown = (e: KeyboardEvent) => {
      if (e.key === "d" || e.key === "D") {
        e.preventDefault();
        setDebugMode((prev) => !prev);
        return;
      }

      if (!debugMode) return;

      if (e.key === "]") {
        e.preventDefault();
        setManualProgress((prev) => Math.min(prev + 0.02, Math.max(slideCount - 1, 0)));
      } else if (e.key === "[") {
        e.preventDefault();
        setManualProgress((prev) => Math.max(prev - 0.02, 0));
      } else if (e.key === "}") {
        e.preventDefault();
        setManualProgress((prev) => Math.min(prev + 0.1, Math.max(slideCount - 1, 0)));
      } else if (e.key === "{") {
        e.preventDefault();
        setManualProgress((prev) => Math.max(prev - 0.1, 0));
      }
    };

    window.addEventListener("keydown", handleGlobalKeyDown);
    return () => window.removeEventListener("keydown", handleGlobalKeyDown);
  }, [debugMode, slideCount]);

  useEffect(() => {
    if (!ENABLE_DEBUG_CONTROLS || !debugMode) return;

    let debugRafId: number;
    const debugLoop = () => {
      setDebugDisplayProgress(scrollProgressRef.current);
      debugRafId = requestAnimationFrame(debugLoop);
    };
    debugRafId = requestAnimationFrame(debugLoop);

    return () => cancelAnimationFrame(debugRafId);
  }, [debugMode]);

  useEffect(() => {
    if (ENABLE_DEBUG_CONTROLS && debugMode) applyTransforms(manualProgress);
  }, [applyTransforms, debugMode, manualProgress]);

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      const scrollContainer = scrollDriverRef.current;
      if (!scrollContainer || slideCount <= 0) return;

      const firstSlide = scrollContainer.querySelector<HTMLElement>(".flipbook-scroll-slide");
      const slideWidth = firstSlide?.offsetWidth ?? scrollContainer.clientWidth;

      if (ENABLE_DEBUG_CONTROLS && (e.key === "d" || e.key === "D")) {
        e.preventDefault();
        setDebugMode((prev) => !prev);
        return;
      }

      if (ENABLE_DEBUG_CONTROLS && debugMode) {
        if (e.key === "]") {
          e.preventDefault();
          setManualProgress((prev) => Math.min(prev + 0.02, Math.max(slideCount - 1, 0)));
        } else if (e.key === "[") {
          e.preventDefault();
          setManualProgress((prev) => Math.max(prev - 0.02, 0));
        } else if (e.key === "}") {
          e.preventDefault();
          setManualProgress((prev) => Math.min(prev + 0.1, Math.max(slideCount - 1, 0)));
        } else if (e.key === "{") {
          e.preventDefault();
          setManualProgress((prev) => Math.max(prev - 0.1, 0));
        }
        return;
      }

      if (e.key === "ArrowRight" || e.key === "ArrowDown") {
        e.preventDefault();
        scrollContainer.scrollBy({ left: slideWidth, behavior: "smooth" });
      } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
        e.preventDefault();
        scrollContainer.scrollBy({ left: -slideWidth, behavior: "smooth" });
      }
    },
    [debugMode, slideCount],
  );

  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    const scrollContainer = scrollDriverRef.current;
    const wrapper = wrapperRef.current;
    if (!scrollContainer || !wrapper) return;

    isDragging.current = true;
    startX.current = e.pageX;
    scrollStart.current = scrollContainer.scrollLeft;
    scrollContainer.style.scrollSnapType = "none";
    scrollContainer.style.scrollBehavior = "auto";
    scrollContainer.style.cursor = "grabbing";
    wrapper.classList.add("is-dragging");
  }, []);

  const handleMouseMove = useCallback((e: React.MouseEvent) => {
    if (!isDragging.current) return;
    const scrollContainer = scrollDriverRef.current;
    if (!scrollContainer) return;

    e.preventDefault();
    scrollContainer.scrollLeft = scrollStart.current - (e.pageX - startX.current);
  }, []);

  const handleMouseUp = useCallback(() => {
    if (!isDragging.current) return;
    const scrollContainer = scrollDriverRef.current;
    const wrapper = wrapperRef.current;
    if (!scrollContainer || !wrapper) return;

    isDragging.current = false;
    scrollContainer.style.scrollSnapType = "x mandatory";
    scrollContainer.style.scrollBehavior = "smooth";
    scrollContainer.style.cursor = "grab";
    wrapper.classList.remove("is-dragging");
  }, []);

  const handleTouchStart = useCallback(() => {
    const wrapper = wrapperRef.current;
    if (!wrapper) return;

    isDragging.current = true;
    wrapper.classList.add("is-dragging");
  }, []);

  const handleTouchEnd = useCallback(() => {}, []);

  return (
    <div className="flipbook-wrapper relative min-h-[50vh] w-full overflow-visible" ref={wrapperRef}>
      <div
        ref={scrollDriverRef}
        className="flipbook-scroll-driver absolute inset-0 z-10 grid cursor-grab grid-flow-col overflow-x-auto overflow-y-hidden scroll-smooth select-none focus:outline-none focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-blue-500/50 active:cursor-grabbing"
        tabIndex={0}
        role="region"
        aria-label={ariaLabel}
        onScroll={wakeRafLoop}
        onKeyDown={handleKeyDown}
        onMouseDown={handleMouseDown}
        onMouseMove={handleMouseMove}
        onMouseUp={handleMouseUp}
        onMouseLeave={handleMouseUp}
        onTouchStart={handleTouchStart}
        onTouchEnd={handleTouchEnd}
        onTouchCancel={handleTouchEnd}
      >
        {slides.map((slide, index) => (
          <div
            key={index}
            className="flipbook-scroll-slide pointer-events-auto flex h-full min-h-full snap-center items-end justify-center opacity-0"
          >
            <span className="text-sm font-medium text-transparent">{slide.title}</span>
          </div>
        ))}
      </div>

      <div
        className="flipbook-stack pointer-events-none absolute left-1/2 z-20"
        style={{ top: "calc(var(--flipbook-card-height) / 2)" }}
        ref={stackRef}
      >
        {slides.map((slide, index) => (
          <div key={index} className="flipbook-card absolute inset-0 h-full w-full">
            <div className="flipbook-card__inner w-full">
              <div
                className="flipbook-card__cover relative flex w-full items-center justify-center overflow-hidden border border-black p-6 sm:p-8"
                style={{ backgroundColor: slide.backgroundColor }}
              >
                <div
                  className="relative z-10 mx-auto flex w-full items-center justify-center"
                  style={{ aspectRatio: "1/1", maxHeight: "100%" }}
                >
                  <img
                    src={slide.mainImage.src}
                    alt={slide.mainImage.alt}
                    className="h-full w-full object-contain select-none"
                    draggable={false}
                  />
                </div>
                {slide.stickers?.map((sticker) => (
                  <img
                    key={`${sticker.position}-${sticker.src}`}
                    src={sticker.src}
                    alt={sticker.alt}
                    className={`pointer-events-none absolute z-30 h-auto select-none ${STICKER_CLASSES[sticker.position]}`}
                    draggable={false}
                  />
                ))}
              </div>
            </div>
          </div>
        ))}
      </div>

      <div
        className="flipbook-captions pointer-events-none absolute right-0 bottom-0 left-0 z-30 text-center"
        style={{ height: "var(--flipbook-caption-height)" }}
      >
        {slides.map((slide, index) => (
          <div
            key={index}
            ref={(el) => {
              if (el) captionRefs.current[index] = el;
            }}
            className="flipbook-caption absolute inset-0 flex flex-col items-center justify-center"
            style={{ opacity: index === 0 ? 1 : 0 }}
            aria-hidden={index !== 0}
          >
            <h3 className="mx-auto max-w-[19em] text-4xl leading-tight lg:text-5xl">{slide.title}</h3>
            <p className="mx-auto mt-3 max-w-2xl text-xl">{slide.subtitle}</p>
          </div>
        ))}
      </div>

      {ENABLE_DEBUG_CONTROLS ? (
        <>
          <button
            onClick={() => setDebugMode((prev) => !prev)}
            style={{
              position: "absolute",
              top: "1rem",
              right: "1rem",
              background: debugMode ? "#ff0" : "#333",
              color: debugMode ? "#000" : "#fff",
              border: "none",
              padding: "0.5rem 1rem",
              borderRadius: "0.25rem",
              cursor: "pointer",
              fontSize: "0.75rem",
              fontFamily: "monospace",
              zIndex: 1000,
            }}
          >
            {debugMode ? "EXIT DEBUG" : "DEBUG"}
          </button>

          {debugMode ? (
            <div
              style={{
                position: "absolute",
                top: "1rem",
                left: "1rem",
                background: "rgba(0,0,0,0.9)",
                color: "#fff",
                padding: "1rem",
                borderRadius: "0.5rem",
                fontSize: "0.75rem",
                fontFamily: "monospace",
                zIndex: 1000,
                maxWidth: "320px",
                height: "400px",
              }}
            >
              <div style={{ marginBottom: "0.5rem", fontWeight: "bold", color: "#ff0" }}>DEBUG MODE</div>
              <div style={{ fontSize: "1rem", marginBottom: "0.5rem" }}>
                Progress: <strong>{debugDisplayProgress.toFixed(3)}</strong>
              </div>
              <div style={{ display: "flex", gap: "0.25rem", marginBottom: "0.5rem" }}>
                <button onClick={() => setManualProgress((prev) => Math.max(prev - 0.1, 0))}>-0.1</button>
                <button onClick={() => setManualProgress((prev) => Math.max(prev - 0.02, 0))}>-0.02</button>
                <button onClick={() => setManualProgress((prev) => Math.min(prev + 0.02, Math.max(slideCount - 1, 0)))}>
                  +0.02
                </button>
                <button onClick={() => setManualProgress((prev) => Math.min(prev + 0.1, Math.max(slideCount - 1, 0)))}>
                  +0.1
                </button>
              </div>
            </div>
          ) : null}
        </>
      ) : null}
    </div>
  );
}
