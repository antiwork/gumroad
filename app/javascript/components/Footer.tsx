import React from "react";
import { Icon } from "$app/components/Icons";

export const Footer = () => {
  return (
    <div className="flex flex-col justify-between gap-16 bg-black px-8 py-16 leading-relaxed text-white lg:flex-row lg:px-[4vw] lg:py-24">
      <div className="flex w-full max-w-3xl flex-col gap-16">
        <div className="flex flex-col gap-8">
          <div className="text-3xl lg:text-5xl lg:leading-tight">
            Subscribe to get tips and tactics to grow the way you want.
          </div>
          <form
            action="https://gumroad.com/follow_from_embed_form"
            method="post"
            className="flex gap-1"
          >
            <input name="seller_id" type="hidden" value="6282492303727" />
            <div className="lg:flex-1">
              <input
                name="email"
                placeholder="Your email address"
                type="email"
                className="w-full rounded-sm border border-transparent bg-white px-4 py-3 text-black placeholder:text-gray-500 focus:border-pink focus:outline-hidden"
              />
            </div>
            <button
              type="submit"
              className="flex h-12 items-center justify-center rounded-sm border border-black bg-pink px-6 text-black transition-transform hover:-translate-y-1 hover:shadow-[4px_4px_0px_0px_rgba(0,0,0,1)] lg:px-8"
            >
              →
            </button>
          </form>
        </div>
        <div className="flex items-center gap-2">
          <img src="/logo-g.svg" alt="Gumroad icon" className="h-6 w-6" />
          <div>Ⓒ Gumroad, Inc.</div>
        </div>
      </div>
      <div className="flex w-full max-w-3xl flex-col gap-16">
        <div className="flex flex-1 gap-16">
          <div className="flex flex-1 flex-col gap-3">
            <a href="/discover" className="no-underline hover:text-pink">
              Discover
            </a>
            <a href="/blog" className="no-underline hover:text-pink">
              Blog
            </a>
            <a href="/pricing" className="no-underline hover:text-pink">
              Pricing
            </a>
            <a href="/features" className="no-underline hover:text-pink">
              Features
            </a>
            <a href="/about" className="no-underline hover:text-pink">
              About
            </a>
            <a href="/small-bets" className="no-underline hover:text-pink">
              Small Bets
            </a>
          </div>
          <div className="flex flex-1 flex-col gap-3">
            <a href="/help" className="no-underline hover:text-pink">
              Help
            </a>
            <a
              href="https://www.youtube.com/playlist?list=PL_DfN-mKCGNuswqERc6sIA8urYAKARc6s"
              className="no-underline hover:text-pink"
            >
              Board meetings
            </a>
            <a href="/terms" className="no-underline hover:text-pink">
              Terms of Service
            </a>
            <a href="/privacy" className="no-underline hover:text-pink">
              Privacy Policy
            </a>
          </div>
        </div>
        <div className="flex justify-between">
          <a href="https://x.com/gumroad" className="hover:text-pink">
            <Icon name={"twitter" as any} />
          </a>
          <a
            href="https://www.youtube.com/channel/UC6o7H5wr2Cf4ibntYEs4Mcg"
            className="hover:text-pink"
          >
            <Icon name={"youtube" as any} />
          </a>
          <a href="https://www.instagram.com/gumroad/" className="hover:text-pink">
            <Icon name={"instagram" as any} />
          </a>
          <a href="https://www.facebook.com/gumroad" className="hover:text-pink">
            <Icon name={"facebook" as any} />
          </a>
          <a href="http://pinterest.com/gumroad" className="hover:text-pink">
             <Icon name={"pinterest" as any} />
          </a>
        </div>
      </div>
    </div>
  );
};
