import Autolinker from "autolinker";
import * as React from "react";

const AutoLink = ({ text }: { text: string }) => {
  const links = Autolinker.parse(text, {});
  return (
    <>
      {text.slice(0, links[0]?.getOffset())}
      {links.map((link, i) => (
        <React.Fragment key={i}>
          <a href={link.getAnchorHref()} target="_blank" rel="noreferrer">
            {link.getAnchorText()}
          </a>
          {text.slice(link.getOffset() + link.getMatchedText().length, links[i + 1]?.getOffset())}
        </React.Fragment>
      ))}
    </>
  );
};

export default AutoLink;
