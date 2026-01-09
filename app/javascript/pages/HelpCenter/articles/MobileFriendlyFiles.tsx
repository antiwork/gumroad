import { Link } from "@inertiajs/react";
import React from "react";

export const meta = {
  description:
    "If you have created a product on Gumroad and want your customers to be able to take full advantage of the Gumroad app (for iOS and Android!), it is important to",
};

export default function MobileFriendlyFiles() {
  return (
    <>
      <div>
        <p>
          If you have created a product on Gumroad and want your customers to be able to take full advantage of the{" "}
          <Link href="/help/article/177-the-gumroad-dashboard-app">Gumroad app</Link> (for iOS and Android!), it is
          important to be aware of the types of files that can be accessed in the Gumroad app.
        </p>
        <p>For your convenience, we've assembled those filetypes here:</p>
        <h3>Audio</h3>
        <ul>
          <li>AIFF</li>
          <li>AAC</li>
          <li>MP3</li>
          <li>VBR</li>
          <li>ALAC</li>
          <li>WAV</li>
          <li>Audible</li>
        </ul>
        <h3>Video </h3>
        <ul>
          <li>H.264</li>
          <li>M4V</li>
          <li>MP4</li>
          <li>MOV</li>
        </ul>
        <h3>Books, etc.</h3>
        <ul>
          <li>PDF</li>
          <li>EPUB</li>
        </ul>
        <h3>Optimizing a PDF for Mobile:</h3>
        <p>
          Some customers would rather download ebooks to their devices instead of using the Gumroad app. For an
          optimized customer service experience, consider uploading multiple ebook formats. Most importantly, always
          upload a PDF version, as most devices can easily display them and don’t require third-party software such as
          .epub or .mobi file formats.
        </p>
        <h3>PDF Settings</h3>
        <p>
          Set the page size to 6x9" and use a 12pt font for the body. Regular PDF defaults tend to make them hard to
          read on mobile because they are generally optimized for print.
        </p>
      </div>
      <div>
        <h3>Related Articles</h3>
        <ul>
          <li>
            <Link href="/help/article/247-what-your-customers-see">
              <span>The Gumroad Library</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/43-streaming-videos">
              <span>Prepare videos for streaming</span>
            </Link>
          </li>
          <li>
            <Link href="/help/article/176-metadata-for-audio-files">
              <span>Metadata for audio files</span>
            </Link>
          </li>
        </ul>
      </div>
    </>
  );
}
