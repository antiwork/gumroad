import * as React from "react";

const NEWLINE_REGEX = /(\r\n|\n|\r)/gmu;

export const Breaklines = ({ text }: { text: string }) => {
  const linesWithBreaks = text.split(NEWLINE_REGEX);

  return (
    <>
      {linesWithBreaks.map((line, idx) => {
        const isBreak = NEWLINE_REGEX.test(line);
        if (isBreak) {
          return <br key={idx} />;
        }
        const isLast = idx === linesWithBreaks.length - 1;
        if (isLast) return <React.Fragment key={idx}>{line}</React.Fragment>;
        return <React.Fragment key={idx}>{line}</React.Fragment>;
      })}
    </>
  );
};
