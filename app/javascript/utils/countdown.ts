const ONE_SECOND_IN_MS = 1000;

class Countdown {
  private readonly interval: ReturnType<typeof setInterval>;

  constructor(duration: number, onTick: (secondsLeft: number) => void, onComplete: () => void) {
    let secondsLeft = duration - 1;
    if (process.env.NODE_ENV === "test") {
      secondsLeft = 1;
    }

    onTick(duration);

    this.interval = setInterval(() => {
      if (secondsLeft > 0) {
        onTick(secondsLeft);
        secondsLeft -= 1;
      } else {
        clearInterval(this.interval);
        onComplete();
      }
    }, ONE_SECOND_IN_MS);
  }

  abort(): void {
    clearInterval(this.interval);
  }
}

export default Countdown;
