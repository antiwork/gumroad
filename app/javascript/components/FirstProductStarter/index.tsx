import * as React from "react";
import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Alert } from "$app/components/ui/Alert";
import { Textarea } from "$app/components/ui/Textarea";

import { OptionCard } from "./Card";
import type { OptionsResponse, ProductOption } from "./types";

import coin1 from "$assets/images/about/coin-1.svg";
import coin2 from "$assets/images/about/coin-2.svg";
import coin3 from "$assets/images/about/coin-3.svg";
import coin4 from "$assets/images/about/coin-4.svg";
import coin5 from "$assets/images/about/coin-5.svg";

const COIN_SOURCES = [coin1, coin2, coin3, coin4, coin5];

const SUBMIT_LABEL = "Show me three options";
const REROLL_LABEL = "Show me three more";
const REROLL_LABEL_CAPPED = "Show me three more templates";
const REROLL_LABEL_REDIRECT = "Create a product from scratch →";
const THINKING_LABEL = "Thinking… up to 5 sec";
const MIN_WORD_COUNT = 2;
const BATCH_SIZE = 3;
const MAX_TEMPLATE_REROLLS = 3;
const ONE_WORD_HELPER = "Add a few more words, or leave it empty to see starter templates.";

const wordCount = (text: string) => text.trim().split(/\s+/u).filter(Boolean).length;
const HELPER_DEBOUNCE_MS = 1000;

const PLACEHOLDER_PREFIX = "Write about yourself and what you plan to sell. E.g.:\n";
const EXAMPLES = [
  "I want to launch a course with a monthly subscription.",
  "I built a macOS app and want to sell licenses for it.",
  "I wrote a niche playbook and want to sell it as an ebook.",
  "I want to offer pay-as-you-want price for my digital product.",
  "I have a newsletter and want to offer paid subscriptions.",
  "I'm building a community and want to monetize it with a monthly membership.",
  "I made a Notion template and want to sell it.",
  "I create VRChat avatars or 3D models and want to sell them.",
];
const MAX_VISIBLE = 3;

type Step = "input" | "loading" | "options" | "error";

export const FirstProductStarter = () => {
  const [step, setStep] = React.useState<Step>("input");
  const [textarea, setTextarea] = React.useState("");
  const [pool, setPool] = React.useState<ProductOption[]>([]);
  const [cursor, setCursor] = React.useState(0);
  const [creatingName, setCreatingName] = React.useState<string | null>(null);
  const [errorMsg, setErrorMsg] = React.useState<string | null>(null);
  const [isFocused, setIsFocused] = React.useState(false);
  const [reloading, setReloading] = React.useState(false);
  const [capped, setCapped] = React.useState(false);
  const [lastSource, setLastSource] = React.useState<"ai" | "templates" | null>(null);
  const [templateRerolls, setTemplateRerolls] = React.useState(0);
  const [doneLines, setDoneLines] = React.useState<string[]>([]);
  const [currentIdx, setCurrentIdx] = React.useState(0);
  const [charCount, setCharCount] = React.useState(0);
  const fetchAbortRef = React.useRef<AbortController | null>(null);
  React.useEffect(() => () => fetchAbortRef.current?.abort(), []);

  React.useEffect(() => {
    if (textarea.length > 0 || isFocused) return;
    const current = EXAMPLES[currentIdx] ?? "";

    if (charCount < current.length) {
      const id = window.setTimeout(() => setCharCount((c) => c + 1), 50);
      return () => window.clearTimeout(id);
    }

    const nextIdx = (currentIdx + 1) % EXAMPLES.length;
    if (doneLines.length < MAX_VISIBLE - 1) {
      const id = window.setTimeout(() => {
        setDoneLines((prev) => [...prev, current]);
        setCurrentIdx(nextIdx);
        setCharCount(0);
      }, 900);
      return () => window.clearTimeout(id);
    }

    const id = window.setTimeout(() => {
      setDoneLines([]);
      setCurrentIdx(nextIdx);
      setCharCount(0);
    }, 3000);
    return () => window.clearTimeout(id);
  }, [textarea, isFocused, currentIdx, charCount, doneLines]);

  const typingLine = `- ${(EXAMPLES[currentIdx] ?? "").slice(0, charCount)}`;
  const allLines = [...doneLines.map((l) => `- ${l}`), typingLine];
  const placeholder = PLACEHOLDER_PREFIX + allLines.join("\n");

  const words = wordCount(textarea);
  const tooFewWords = words > 0 && words < MIN_WORD_COUNT;
  const submitDisabled = step === "loading" || reloading || tooFewWords;

  const [debouncedTooFew, setDebouncedTooFew] = React.useState(false);
  React.useEffect(() => {
    const id = window.setTimeout(() => setDebouncedTooFew(tooFewWords), HELPER_DEBOUNCE_MS);
    return () => window.clearTimeout(id);
  }, [tooFewWords]);
  const showHelper = tooFewWords && debouncedTooFew;

  const visible = pool.slice(cursor, cursor + BATCH_SIZE);
  const exhausted = cursor + BATCH_SIZE >= pool.length;

  const fetchPool = async () => {
    const wasOnOptions = step === "options";
    if (wasOnOptions) {
      setReloading(true);
    } else {
      setStep("loading");
    }
    setErrorMsg(null);
    const controller = new AbortController();
    fetchAbortRef.current = controller;
    const timeoutId = window.setTimeout(() => controller.abort(), 45_000);
    try {
      const res = await request({
        accept: "json",
        method: "POST",
        url: "/first_product_starter/options",
        data: { textarea_answer: textarea },
        abortSignal: controller.signal,
      });
      if (!res.ok) throw new ResponseError(`Server returned ${String(res.status)}`);
      const json = cast<OptionsResponse>(await res.json());
      setPool(json.options);
      setCursor(0);
      setCapped(json.capped ?? false);
      const source = json.source ?? null;
      setLastSource(source);
      if (source === "ai") setTemplateRerolls(0);
      setStep("options");
    } catch {
      setErrorMsg("Taking a while — try once more?");
      if (!wasOnOptions) setStep("error");
    } finally {
      setReloading(false);
      window.clearTimeout(timeoutId);
      if (fetchAbortRef.current === controller) fetchAbortRef.current = null;
    }
  };

  const submit = async () => {
    if (submitDisabled) return;
    await fetchPool();
  };

  const onTemplatesPath = lastSource === "templates" || capped;
  const nextClickRedirects = onTemplatesPath && templateRerolls >= MAX_TEMPLATE_REROLLS;

  const reroll = () => {
    if (creatingName !== null || reloading) return;

    if (nextClickRedirects) {
      window.location.href = Routes.new_product_path();
      return;
    }
    if (onTemplatesPath) setTemplateRerolls((c) => c + 1);

    if (exhausted) {
      void fetchPool();
    } else {
      setCursor(cursor + BATCH_SIZE);
    }
  };

  const create = async (option: ProductOption) => {
    if (creatingName) return;
    setCreatingName(option.name);
    setErrorMsg(null);
    try {
      const res = await request({
        accept: "json",
        method: "POST",
        url: "/first_product_starter/draft",
        data: {
          option: {
            name: option.name,
            description: option.description,
            native_type: option.native_type,
            price_range: String(option.price_cents / 100),
            price_currency_type: "usd",
            subscription_duration: option.native_type === "membership" ? "monthly" : undefined,
          },
        },
      });
      if (!res.ok) throw new ResponseError(`Server returned ${String(res.status)}`);
      const json = cast<{ redirect_url: string }>(await res.json());
      window.location.href = json.redirect_url;
    } catch {
      setErrorMsg("Couldn't create the product. Try once more?");
      setCreatingName(null);
    }
  };

  if (step === "input" || step === "loading" || step === "error") {
    return (
      <div className="flex flex-col gap-4">
        <h2>What do you want to sell? We'll draft it for you.</h2>
        <div className="relative">
          <Textarea
            value={textarea}
            onChange={(e) => setTextarea(e.target.value)}
            onFocus={() => setIsFocused(true)}
            onBlur={() => setIsFocused(false)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey && !submitDisabled) {
                e.preventDefault();
                void submit();
              }
            }}
            placeholder={placeholder}
            aria-label="Tell us what you know, make, teach, or want to sell"
            aria-busy={step === "loading"}
            disabled={step === "loading"}
            rows={4}
            maxLength={500}
            className={step === "loading" ? "opacity-30" : undefined}
          />
          {step === "loading" ? (
            <div
              className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center gap-3"
              role="status"
              aria-live="polite"
            >
              <div className="flex items-end gap-2">
                {COIN_SOURCES.map((src, i) => (
                  <img
                    key={src}
                    src={src}
                    alt=""
                    className="size-8 animate-bounce"
                    style={{ animationDelay: `${String(i * 120)}ms`, animationDuration: "900ms" }}
                  />
                ))}
              </div>
              <p className="text-sm text-muted">Thinking through options for you — this can take up to 5 seconds.</p>
            </div>
          ) : null}
        </div>
        {showHelper ? <p className="text-sm text-muted">{ONE_WORD_HELPER}</p> : null}
        {errorMsg ? <Alert variant="danger">{errorMsg}</Alert> : null}
        <Button onClick={submit} disabled={submitDisabled} color="accent" className="self-start">
          {step === "loading" ? THINKING_LABEL : SUBMIT_LABEL}
        </Button>
      </div>
    );
  }

  const rerollLabel = (() => {
    if (reloading) return THINKING_LABEL;
    if (nextClickRedirects) return REROLL_LABEL_REDIRECT;
    return capped ? REROLL_LABEL_CAPPED : REROLL_LABEL;
  })();

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-baseline gap-x-4 gap-y-2">
        <h2>Start with a template</h2>
        <button
          type="button"
          onClick={reroll}
          disabled={creatingName !== null || reloading}
          className={
            nextClickRedirects
              ? "text-sm font-medium underline disabled:no-underline disabled:opacity-50"
              : "text-sm text-muted underline disabled:no-underline disabled:opacity-50"
          }
        >
          {rerollLabel}
        </button>
      </div>
      {capped ? (
        <Alert variant="info">
          You've used your AI suggestions for this hour. Here are starter templates — or{" "}
          <a href={Routes.new_product_path()} className="underline">
            create a product from scratch
          </a>
          .
        </Alert>
      ) : null}
      <div data-testid="product-options" className="grid gap-4 md:grid-cols-3">
        {visible.map((option) => (
          <OptionCard
            key={option.name}
            option={option}
            onCreate={() => create(option)}
            creating={creatingName === option.name}
            disabled={creatingName !== null && creatingName !== option.name}
          />
        ))}
      </div>
      {errorMsg ? <Alert variant="danger">{errorMsg}</Alert> : null}
    </div>
  );
};
